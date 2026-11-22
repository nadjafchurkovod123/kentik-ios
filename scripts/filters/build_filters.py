#!/usr/bin/env python3
"""Сборка списков фильтров Kentik: текстовые списки (ABP/uBO/AdGuard) → JSON WKContentRuleList.

Использование:
  build_filters.py --converter <ConverterTool> --out <папка> [--work <папка>] [--version <yyyyMMddHHmm>]

Что делает:
  1. Скачивает источники из sources.json (с зеркалами и повторами), раскрывает !#include,
     вычисляет препроцессор !#if/!#else/!#endif (как для uBO/AdGuard в Safari на iPhone).
  2. Склеивает источники по категориям (ads, ru, annoyances, privacy, security), убирает дубли,
     в каждую категорию дописывает «исправления» (uBO unbreak + quick-fixes): исключения
     WebKit действуют только внутри своего списка.
  3. Конвертирует каждую категорию AdGuard SafariConverterLib (ConverterTool convert) для
     каждой версии WebKit (s26 — iOS 26+, s16 — iOS 16.4–25). Если правил больше лимита
     WebKit (150 000 на список) или конвертер что-то отбросил, категория делится на части.
  4. Пишет <id>.<variant>.<version>.json.deflate (сырой DEFLATE, как COMPRESSION_ZLIB в iOS)
     и manifest.json (версия + sha256 + размеры + число правил), печатает отчёт по счётчикам
     и сброшенным правилам, дописывает его в $GITHUB_STEP_SUMMARY.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
WEBKIT_LIMIT = 150_000
# Запас под правила, которые WebKit может развернуть при компиляции.
SAFE_LIMIT = 145_000
USER_AGENT = "KentikFilterBuilder/1.0 (+https://github.com/nadjafchurkovod123/kentik-ios)"

# Токены препроцессора, истинные для нашей среды (WebKit на iPhone, только сетевые и CSS-правила).
TRUE_TOKENS = {
    "env_safari", "env_mobile",
    "adguard", "adguard_ext_safari", "adguard_app_ios",
}


def log(msg: str) -> None:
    print(msg, flush=True)


# ─────────────────────────────── Скачивание ───────────────────────────────

def fetch(url: str, attempts: int = 3) -> str:
    last = None
    for i in range(attempts):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(req, timeout=60) as resp:
                data = resp.read()
            return data.decode("utf-8", errors="replace")
        except Exception as exc:  # noqa: BLE001 — сеть ненадёжна, пробуем ещё
            last = exc
            time.sleep(2 * (i + 1))
    raise RuntimeError(f"не скачался {url}: {last}")


def fetch_source(source_id: str, source: dict) -> tuple[str, str]:
    # Свой список в репозитории (scripts/filters/<файл>), без сети.
    if source.get("file"):
        path = os.path.join(HERE, source["file"])
        with open(path, encoding="utf-8") as f:
            return "file://" + path, f.read()
    errors = []
    for url in source["urls"]:
        try:
            return url, fetch(url)
        except RuntimeError as exc:
            errors.append(str(exc))
            log(f"  ! {source_id}: {exc}")
    raise RuntimeError(f"{source_id}: ни одно зеркало не ответило: {errors}")


# ─────────────────────────────── Препроцессор ───────────────────────────────

_TOKEN_RE = re.compile(r"\s*(\(|\)|!|&&|\|\||[A-Za-z0-9_]+)")


def eval_condition(expr: str) -> bool:
    """Вычисляет условие !#if: идентификаторы, !, &&, ||, скобки. Неизвестное — ложь."""
    tokens = []
    pos = 0
    expr = expr.strip()
    while pos < len(expr):
        m = _TOKEN_RE.match(expr, pos)
        if not m:
            return False
        tokens.append(m.group(1))
        pos = m.end()
        while pos < len(expr) and expr[pos].isspace():
            pos += 1
    idx = 0

    def peek():
        return tokens[idx] if idx < len(tokens) else None

    def take():
        nonlocal idx
        tok = peek()
        idx += 1
        return tok

    def parse_or():
        val = parse_and()
        while peek() == "||":
            take()
            rhs = parse_and()
            val = val or rhs
        return val

    def parse_and():
        val = parse_not()
        while peek() == "&&":
            take()
            rhs = parse_not()
            val = val and rhs
        return val

    def parse_not():
        if peek() == "!":
            take()
            return not parse_not()
        return parse_atom()

    def parse_atom():
        tok = take()
        if tok == "(":
            val = parse_or()
            if peek() == ")":
                take()
            return val
        if tok is None:
            return False
        if tok == "true":
            return True
        return tok in TRUE_TOKENS

    try:
        return bool(parse_or())
    except Exception:  # noqa: BLE001
        return False


def preprocess(text: str, base_url: str, depth: int = 0) -> list[str]:
    """Раскрывает !#include (тот же хост) и !#if, выкидывает комментарии и пустые строки."""
    out: list[str] = []
    # Стек: (родитель активен, текущая ветка активна)
    stack: list[tuple[bool, bool]] = []
    active = True
    base_host = urllib.parse.urlparse(base_url).netloc
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line.startswith("!#if"):
            cond = eval_condition(line[4:])
            stack.append((active, cond))
            active = active and cond
            continue
        if line.startswith("!#else"):
            if stack:
                parent, cond = stack[-1]
                stack[-1] = (parent, not cond)
                active = parent and not cond
            continue
        if line.startswith("!#endif"):
            if stack:
                parent, _ = stack.pop()
                active = parent
            continue
        if not active:
            continue
        if line.startswith("!#include"):
            target = line[len("!#include"):].strip()
            url = urllib.parse.urljoin(base_url, target)
            if depth < 3 and urllib.parse.urlparse(url).netloc == base_host:
                try:
                    out.extend(preprocess(fetch(url), url, depth + 1))
                except RuntimeError as exc:
                    log(f"  ! include {url}: {exc}")
            continue
        if line.startswith("!") or line.startswith("["):
            continue
        if line == "#" or line.startswith("# "):
            continue
        out.append(line)
    return out


# ─────────────────────────────── Конвертация ───────────────────────────────

def run_converter(converter: str, rules: list[str], safari: str, work: str, tag: str) -> dict:
    path = os.path.join(work, f"{tag}.txt")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(rules))
        f.write("\n")
    started = time.time()
    proc = subprocess.run(
        [converter, "convert", "--safari-version", safari, "--advanced-blocking", "true",
         "--input-path", path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
    )
    if proc.returncode != 0:
        sys.stderr.write(proc.stderr.decode("utf-8", errors="replace")[-4000:])
        raise RuntimeError(f"ConverterTool завершился с кодом {proc.returncode} ({tag})")
    out = proc.stdout.decode("utf-8")
    start = out.find("{")
    result = json.loads(out[start:])
    result["_seconds"] = round(time.time() - started, 1)
    rules_json = json.loads(result["safariRulesJSON"])
    if not isinstance(rules_json, list):
        raise RuntimeError(f"{tag}: конвертер вернул не массив правил")
    result["_rules"] = rules_json
    return result


def split_chunks(chunks: list[tuple[str, list[str]]]) -> tuple[list, list]:
    """Делит список (источник, строки) пополам по числу строк; один источник режется по строкам."""
    if len(chunks) == 1:
        sid, lines = chunks[0]
        mid = len(lines) // 2
        return [(sid + "#1", lines[:mid])], [(sid + "#2", lines[mid:])]
    total = sum(len(c[1]) for c in chunks)
    acc = 0
    for i, (_, lines) in enumerate(chunks):
        acc += len(lines)
        if acc >= total / 2:
            cut = max(1, min(i + 1, len(chunks) - 1))
            return chunks[:cut], chunks[cut:]
    return chunks[:1], chunks[1:]


def convert_category(converter, chunks, fixes, safari, work, tag, depth=0):
    """Возвращает список частей [(rules_json, result, chunk_ids)]."""
    seen = set()
    rules = []
    for _, lines in chunks:
        for line in lines:
            if line not in seen:
                seen.add(line)
                rules.append(line)
    for line in fixes:
        if line not in seen:
            seen.add(line)
            rules.append(line)
    result = run_converter(converter, rules, safari, work, tag)
    count = len(result["_rules"])
    over = result.get("discardedSafariRules", 0) > 0 or count > SAFE_LIMIT
    if over and depth < 4 and sum(len(c[1]) for c in chunks) > 1000:
        log(f"    {tag}: {count} правил, отброшено {result.get('discardedSafariRules', 0)} — делю на части")
        left, right = split_chunks(chunks)
        return (convert_category(converter, left, fixes, safari, work, tag + "a", depth + 1)
                + convert_category(converter, right, fixes, safari, work, tag + "b", depth + 1))
    return [(result["_rules"], result, [c[0] for c in chunks], len(rules))]


def deflate(data: bytes) -> bytes:
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    return comp.compress(data) + comp.flush()


# ─────────────────────────────── Главное ───────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--converter", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--work", default="build/filters-work")
    ap.add_argument("--config", default=os.path.join(HERE, "sources.json"))
    ap.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M"))
    ap.add_argument("--converter-version", default="SafariConverterLib")
    args = ap.parse_args()

    with open(args.config, encoding="utf-8") as f:
        config = json.load(f)
    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.work, exist_ok=True)
    for name in os.listdir(args.out):
        if name.endswith(".json.deflate") or name == "manifest.json":
            os.remove(os.path.join(args.out, name))

    # 1. Скачивание и препроцессор.
    log("== Источники ==")
    texts: dict[str, list[str]] = {}
    source_meta = []
    needed = set(config["fixes"])
    for lst in config["lists"]:
        needed.update(lst["sources"])
    for sid in sorted(needed):
        src = config["sources"][sid]
        try:
            url, text = fetch_source(sid, src)
        except RuntimeError as exc:
            if src.get("optional"):
                log(f"  ! {sid}: необязательный источник пропущен ({exc})")
                texts[sid] = []
                continue
            raise
        lines = preprocess(text, url)
        texts[sid] = lines
        version = ""
        m = re.search(r"^!\s*(?:Version|Last modified):\s*(.+)$", text, re.MULTILINE)
        if m:
            version = m.group(1).strip()
        source_meta.append({"id": sid, "title": src["title"], "url": url, "rules": len(lines), "version": version})
        log(f"  {sid:26} {len(lines):7} строк  {version}")

    fixes: list[str] = []
    for sid in config["fixes"]:
        fixes.extend(texts.get(sid, []))

    # 2–4. Конвертация по категориям и версиям WebKit.
    manifest_lists = []
    report = ["| Список | WebKit | Источник, строк | Правил JSON | Не сконвертировано | Отброшено лимитом | Продвинутых (не в JSON) | JSON, МБ | DEFLATE, МБ | с |",
              "|---|---|---|---|---|---|---|---|---|---|"]
    total_by_variant: dict[str, int] = {}
    for variant in config["variants"]:
        vid, safari = variant["id"], variant["safari"]
        log(f"== Конвертация для WebKit {safari} ({vid}) ==")
        for lst in config["lists"]:
            chunks = [(sid, texts.get(sid, [])) for sid in lst["sources"] if texts.get(sid)]
            if not chunks:
                log(f"  ! {lst['id']}: нет источников, пропускаю")
                continue
            parts = convert_category(args.converter, chunks, fixes, safari, args.work, f"{lst['id']}.{vid}")
            for n, (rules_json, result, chunk_ids, src_count) in enumerate(parts, start=1):
                list_id = lst["id"] if len(parts) == 1 else f"{lst['id']}-{n}"
                if not rules_json:
                    log(f"  ! {list_id}: пустой результат, пропускаю")
                    continue
                payload = json.dumps(rules_json, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                packed = deflate(payload)
                fname = f"{list_id}.{vid}.{args.version}.json.deflate"
                with open(os.path.join(args.out, fname), "wb") as f:
                    f.write(packed)
                entry = {
                    "id": list_id,
                    "variant": vid,
                    "title": lst["title"],
                    "file": fname,
                    "sha256": hashlib.sha256(packed).hexdigest(),
                    "bytes": len(packed),
                    "jsonBytes": len(payload),
                    "rules": len(rules_json),
                    "sources": chunk_ids,
                }
                manifest_lists.append(entry)
                total_by_variant[vid] = total_by_variant.get(vid, 0) + len(rules_json)
                discarded = result.get("discardedSafariRules", 0)
                errors = result.get("errorsCount", 0)
                advanced = result.get("advancedRulesCount", 0)
                log(f"  {list_id:14} {vid}: источник {src_count} → правил {len(rules_json)}; "
                    f"не сконвертировано {errors}; отброшено лимитом {discarded}; продвинутых {advanced}; "
                    f"JSON {len(payload) / 1e6:.1f} МБ → {len(packed) / 1e6:.2f} МБ; {result['_seconds']} с")
                report.append(f"| {list_id} | {vid} | {src_count} | {len(rules_json)} | {errors} | {discarded} | "
                              f"{advanced} | {len(payload) / 1e6:.1f} | {len(packed) / 1e6:.2f} | {result['_seconds']} |")
                if len(rules_json) > WEBKIT_LIMIT:
                    raise RuntimeError(f"{list_id}.{vid}: {len(rules_json)} правил больше лимита WebKit")

    if not manifest_lists:
        raise RuntimeError("не собран ни один список")

    manifest = {
        "schema": 1,
        "version": args.version,
        "generated": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "converter": args.converter_version,
        "lists": manifest_lists,
        "sources": source_meta,
    }
    with open(os.path.join(args.out, "manifest.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)

    log("== Итого ==")
    for vid, total in total_by_variant.items():
        log(f"  {vid}: {total} правил в {sum(1 for e in manifest_lists if e['variant'] == vid)} списках")
    log(f"  версия {args.version}")

    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"## Списки фильтров {args.version}\n\n")
            f.write("\n".join(report) + "\n\n")
            f.write("| Источник | Строк | Версия |\n|---|---|---|\n")
            for s in source_meta:
                f.write(f"| {s['title']} | {s['rules']} | {s['version']} |\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
