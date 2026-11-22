#!/usr/bin/env python3
"""Скриптлеты AdGuard для Kentik (YouTube и др.): правила `#%#` из AdGuard Base (версия для
Safari) + официальная библиотека скриптлетов AdGuard → готовые к внедрению скрипты.

Использование:
  build_adguard.py <файл-вывода.json> [--version yyyyMMddHHmm] [--manifest manifest.json]
                   [--rules <файл>] [--library <файл>]

Зачем. Списки WKContentRuleList не умеют менять ответы сервера, поэтому рекламу внутри
плеера YouTube (те же хосты googlevideo.com) ими не убрать. AdGuard делает это скриптлетами:
set-constant google_ad_status=1 (с исключением для static.doubleclick.net/instream/ad_status.js
в сетевых правилах), json-prune / json-prune-xhr-response / json-prune-fetch-response ответа
плеера (adPlacements, playerAds, adSlots), перепись запроса плеера, настройки EXPERIMENT_FLAGS.
Эти правила меняются по нескольку раз в неделю — поэтому они едут вместе со списками фильтров
(релиз «lists», ключ "adguard" манифеста), а не только с новой сборкой приложения.

Что делает:
  1. Скачивает AdGuard Base для Safari (filters.adtidy.org/extension/safari/filters/2.txt —
     в нём уже учтены подсказки платформы для Safari) и сборку @adguard/scriptlets для
     интеграций (dist/scriptlets.corelibs.json: имена, в том числе имена uBO, и тела функций
     `function(source, args)`; мажорная версия закреплена — формат сборки её API).
  2. Берёт только правила `#%#` (скриптлеты и JS-правила — список AdGuard, им можно и
     JS, и trusted-скриптлеты) и исключения `#@%#`, у которых среди доменов есть домен из
     SCOPE; домены правила урезаются до SCOPE — правило действует только там, где его
     назвали, и только на этих сайтах. Модификаторы `[$domain=…,path=…]` понимаются.
  3. Исключения складываются в «не на этих сайтах» соответствующих правил.
  4. Пишет готовые скрипты: один со скриптлетами (только нужные функции библиотеки) и по
     одному на каждое JS-правило (синтаксическая ошибка в одном правиле не роняет остальные).
     Каждый скрипт сам проверяет хост и путь фрейма. Проверка синтаксиса — `node --check`
     (если node есть), скрипт с ошибкой выбрасывается.

Формат вывода: {"schema": 1, "version", "library", "source", "hosts": [...], "rules": N,
"scripts": [{"kind": "scriptlets"|"js", "rules": N, "source": "..."}], "missing": [...]}.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from build_filters import eval_condition  # noqa: E402

RULES_URLS = [
    "https://filters.adtidy.org/extension/safari/filters/2.txt",
    "https://filters.adtidy.org/ios/filters/2.txt",
]
LIBRARY_URLS = [
    "https://cdn.jsdelivr.net/npm/@adguard/scriptlets@2/dist/scriptlets.corelibs.json",
    "https://unpkg.com/@adguard/scriptlets@2/dist/scriptlets.corelibs.json",
]
USER_AGENT = "KentikFilterBuilder/1.0 (+https://github.com/nadjafchurkovod123/kentik-ios)"

# Сайты, для которых берутся правила (и их поддомены).
SCOPE = ["youtube.com", "youtube-nocookie.com", "youtubekids.com"]

# Скриптлеты для фреймов (плееры сериалов и вообще рунет): правила с доменами из этих списков.
# Ставятся во ВСЕ фреймы всех страниц (щит включён), каждый вызов сам сверяет хост своего
# фрейма — так `kodik.info##+js(json-prune, vast)` срабатывает внутри iframe Kodik на любом
# сайте с сериалами. trusted-скриптлеты — только из списков AdGuard и своих (как в AdGuard/uBO).
FRAME_SOURCES = [
    {"id": "adguard-russian", "title": "AdGuard Russian (Safari)", "syntax": "adguard", "trusted": True,
     "urls": ["https://filters.adtidy.org/extension/safari/filters/1.txt",
              "https://filters.adtidy.org/ios/filters/1.txt"]},
    {"id": "ruadlist", "title": "RU AdList (uBO)", "syntax": "ubo", "trusted": False,
     "urls": ["https://raw.githubusercontent.com/dimisa-RUAdList/RUAdListCDN/main/lists/ruadlist.ubo.min.txt",
              "https://cdn.jsdelivr.net/gh/dimisa-RUAdList/RUAdListCDN@main/lists/ruadlist.ubo.min.txt"]},
    {"id": "kentik", "title": "Kentik", "syntax": "adguard", "trusted": True, "file": "kentik-scriptlets.txt"},
]

# Меньше — что-то сломалось (источник изменился): такой набор не публикуем.
MIN_RULES = 5


def log(msg: str) -> None:
    print(msg, flush=True)


def fetch(urls: list[str]) -> tuple[str, str]:
    errors = []
    for url in urls:
        for attempt in range(3):
            try:
                req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
                with urllib.request.urlopen(req, timeout=60) as resp:
                    return url, resp.read().decode("utf-8", errors="replace")
            except Exception as exc:  # noqa: BLE001 — сеть ненадёжна
                errors.append(f"{url}: {exc}")
    raise RuntimeError("; ".join(errors[-3:]))


# ─────────────────────────────── Разбор правил ───────────────────────────────

def in_scope(domain: str) -> bool:
    d = domain.lower()
    if d.endswith(".*"):
        stem = d[:-2]
        return any(s.split(".")[0] == stem.split(".")[-1] for s in SCOPE)
    return any(d == s or d.endswith("." + s) for s in SCOPE)


def parse_args_list(s: str):
    """Аргументы скриптлета: строки в '' или "" через запятую (снимается только своё \\')."""
    out, i, n = [], 0, len(s)
    while True:
        while i < n and s[i].isspace():
            i += 1
        if i >= n:
            break
        q = s[i]
        if q not in "'\"":
            return None
        i += 1
        arg, closed = [], False
        while i < n:
            c = s[i]
            if c == "\\" and i + 1 < n and s[i + 1] == q:
                arg.append(q)
                i += 2
                continue
            if c == q:
                closed = True
                i += 1
                break
            arg.append(c)
            i += 1
        if not closed:
            return None
        out.append("".join(arg))
        while i < n and s[i].isspace():
            i += 1
        if i >= n:
            break
        if s[i] != ",":
            return None
        i += 1
    return out


def parse_modifiers(text: str):
    """`domain=a.com|~b.com,path=/x` → (domains, negated, path); неизвестный модификатор — None."""
    parts: list[str] = []
    for piece in text.split(","):
        if parts and not re.match(r"^(domain|path|url)=", piece):
            parts[-1] += "," + piece
        else:
            parts.append(piece)
    domains, negated, path = [], [], None
    for part in parts:
        name, _, value = part.partition("=")
        if name == "domain":
            if value.startswith("/"):
                return None
            for d in value.split("|"):
                d = d.strip().lower()
                if not d:
                    continue
                (negated if d.startswith("~") else domains).append(d.lstrip("~"))
        elif name == "path":
            path = value
        else:
            return None
    return domains, negated, path


def parse_line(line: str):
    """Правило `#%#` / `#@%#` → dict или None."""
    line = line.strip()
    mods = ([], [], None)
    if line.startswith("[$"):
        end = line.find("]")
        if end < 0:
            return None
        parsed = parse_modifiers(line[2:end])
        if parsed is None:
            return None
        mods = parsed
        line = line[end + 1:]
    m = re.match(r"^([^#]*)(#@?%#)(.*)$", line)
    if not m:
        return None
    domains_text, sep, body = m.group(1), m.group(2), m.group(3).strip()
    exception = sep == "#@%#"
    domains, negated = list(mods[0]), list(mods[1])
    for d in domains_text.split(","):
        d = d.strip().lower()
        if not d:
            continue
        if d.startswith("/") or d.startswith("~/"):
            return None
        (negated if d.startswith("~") else domains).append(d.lstrip("~"))
    rule = {"ex": exception, "d": domains, "n": negated, "p": mods[2]}
    if body.startswith("//scriptlet("):
        if not body.endswith(")"):
            return None
        args = parse_args_list(body[len("//scriptlet("):-1])
        if args is None:
            return None
        rule["k"] = "s"
        rule["a"] = args if args else [""]
    else:
        if not body:
            return None
        rule["k"] = "j"
        rule["b"] = body
    return rule


def split_ubo_args(s: str) -> list[str]:
    """Аргументы `##+js(имя, a, b)` uBO: через запятую; запятая с обратной косой — внутри аргумента."""
    out, cur, i = [], [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s) and s[i + 1] == ",":
            cur.append(",")
            i += 2
            continue
        if c == ",":
            out.append("".join(cur).strip())
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    out.append("".join(cur).strip())
    # Аргумент в кавычках целиком — кавычки снимаем (так пишут, когда в нём пробелы по краям).
    return [a[1:-1] if len(a) >= 2 and a[0] == a[-1] and a[0] in "'\"" else a for a in out]


def parse_ubo_line(line: str):
    """Правило uBO `домены##+js(...)` / `домены#@#+js(...)` → dict как у parse_line или None."""
    m = re.match(r"^([^#]*)#(@?)#\+js\((.*)\)$", line.strip())
    if not m:
        return None
    domains, negated = [], []
    for d in m.group(1).split(","):
        d = d.strip().lower()
        if not d:
            continue
        if d.startswith("/") or d.startswith("~/"):
            return None
        (negated if d.startswith("~") else domains).append(d.lstrip("~"))
    body = m.group(3).strip()
    args = split_ubo_args(body) if body else [""]
    return {"ex": m.group(2) == "@", "d": domains, "n": negated, "p": None, "k": "s", "a": args}


def extract(text: str, syntax: str = "adguard", scope=None) -> list[dict]:
    """Правила `#%#`/`#@%#` (AdGuard) или `##+js`/`#@#+js` (uBO) из текста списка с учётом !#if.
    scope — функция «домен подходит» (по умолчанию SCOPE); None-домены не берутся."""
    scope = scope or in_scope
    rules, stack, active = [], [], True
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
                active = stack.pop()[0]
            continue
        if not active or line.startswith("!"):
            continue
        if syntax == "ubo":
            if "#+js(" not in line:
                continue
            rule = parse_ubo_line(line)
        else:
            if "%#" not in line:
                continue
            rule = parse_line(line)
        if not rule:
            continue
        scoped = [d for d in rule["d"] if scope(d)]
        if not scoped and not (rule["ex"] and not rule["d"]):
            continue
        rule["d"] = scoped
        rule["n"] = [d for d in rule["n"] if scope(d)]
        rules.append(rule)
    return rules


# ─────────────────────────────── Библиотека ───────────────────────────────

class Library:
    def __init__(self, text: str):
        data = json.loads(text)
        self.version = str(data.get("version", ""))
        self.bodies: list[str] = []
        self.names: dict[str, int] = {}
        for i, sc in enumerate(data["scriptlets"]):
            self.bodies.append(sc["scriptlet"])
            for name in sc["names"]:
                self.names[name] = i
        if len(self.bodies) < 20:
            raise RuntimeError("библиотека скриптлетов подозрительно маленькая")

    def index(self, name: str):
        if name in self.names:
            return self.names[name]
        base = name[:-3] if name.endswith(".js") else name
        for candidate in (base, f"ubo-{base}.js", f"ubo-{base}", f"{base}.js"):
            if candidate in self.names:
                return self.names[candidate]
        return None


# ─────────────────────────────── Скрипты ───────────────────────────────

# Проверка хоста и пути фрейма; d — домены (example.com, example.*), n — исключённые,
# p — подстрока пути (с *) или /регулярка/.
MATCH_JS = r"""var h=String(location.hostname||'').toLowerCase(),u=String(location.pathname||'')+String(location.search||'');
function dm(d){if(d.slice(-2)==='.*'){var s=d.slice(0,-1),i=h.indexOf(s);return i===0||(i>0&&h.charAt(i-1)==='.');}return h===d||(h.length>d.length&&h.slice(-d.length-1)==='.'+d);}
function pm(p){if(!p)return true;if(p.length>2&&p.charAt(0)==='/'&&p.slice(-1)==='/'){try{return new RegExp(p.slice(1,-1)).test(u);}catch(e){return false;}}
var parts=p.split('*'),pos=0;for(var i=0;i<parts.length;i++){if(!parts[i])continue;var k=u.indexOf(parts[i],pos);if(k<0)return false;pos=k+parts[i].length;}return true;}
function ok(r){return r.d.some(dm)&&!r.n.some(dm)&&pm(r.p);}
"""


def same_scriptlet(lib: Library, exc: dict, rule: dict) -> bool:
    name = exc["a"][0]
    if name == "":
        return True
    a, b = lib.index(name), lib.index(rule["a"][0])
    same = name == rule["a"][0] or (a is not None and a == b)
    return same and (len(exc["a"]) == 1 or exc["a"][1:] == rule["a"][1:])


def apply_exceptions(rules: list[dict], lib: Library) -> list[dict]:
    """Исключения → «не на этих сайтах» у правил; полностью отменённые правила убираются."""
    exceptions = [r for r in rules if r["ex"]]
    out = []
    for rule in rules:
        if rule["ex"]:
            continue
        cancelled = False
        for e in exceptions:
            if e["k"] != rule["k"]:
                continue
            if rule["k"] == "s" and not same_scriptlet(lib, e, rule):
                continue
            if rule["k"] == "j" and e["b"] != rule["b"]:
                continue
            if e["p"] and e["p"] != rule["p"]:
                continue
            # Исключение без доменов (везде) или на тех же (или более общих) доменах отменяет
            # правило совсем.
            if not e["d"] or all(any(d == x or d.endswith("." + x) for x in e["d"]) for d in rule["d"]):
                cancelled = True
                break
            rule["n"] = sorted(set(rule["n"]) | set(e["d"]))
        if not cancelled:
            out.append(rule)
    return out


def rule_json(rule: dict) -> str:
    return json.dumps({"d": rule["d"], "n": rule["n"], "p": rule["p"]}, ensure_ascii=False, separators=(",", ":"))


def scriptlets_script(rules: list[dict], lib: Library):
    used: list[int] = []
    calls, missing = [], []
    for r in rules:
        idx = lib.index(r["a"][0])
        if idx is None:
            missing.append(r["a"][0])
            continue
        if idx not in used:
            used.append(idx)
        calls.append(f"[{rule_json(r)},{used.index(idx)},{json.dumps(r['a'], ensure_ascii=False)}]")
    if not calls:
        return None, missing
    funcs = ",\n".join(lib.bodies[i] for i in used)
    source = (
        "(function(){\n" + MATCH_JS +
        "var F=[\n" + funcs + "\n];\n"
        "var C=[\n" + ",\n".join(calls) + "\n];\n"
        "for(var i=0;i<C.length;i++){var c=C[i];if(!ok(c[0]))continue;"
        "try{F[c[1]]({name:c[2][0],args:c[2].slice(1),engine:'corelibs',version:" + json.dumps(lib.version) +
        ",verbose:false,ruleText:''},c[2].slice(1));}catch(e){}}\n"
        "})();"
    )
    return {"kind": "scriptlets", "rules": len(calls), "source": source}, missing


def js_script(rule: dict) -> dict:
    source = (
        "(function(){\n" + MATCH_JS +
        "if(!ok(" + rule_json(rule) + "))return;\n"
        "try{\n" + rule["b"] + "\n}catch(e){}\n"
        "})();"
    )
    return {"kind": "js", "rules": 1, "source": source}


def syntax_ok(source: str) -> bool:
    node = shutil.which("node")
    if not node:
        return True
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False, encoding="utf-8") as f:
        f.write(source)
        path = f.name
    try:
        proc = subprocess.run([node, "--check", path], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if proc.returncode != 0:
            log("  ! синтаксис: " + proc.stderr.decode("utf-8", errors="replace").strip().splitlines()[-1][:200])
        return proc.returncode == 0
    finally:
        os.unlink(path)


def frame_scope(domain: str) -> bool:
    """Для фреймов — любые домены, кроме YouTube (его правила ставятся отдельно, по сайту)."""
    return bool(domain) and not in_scope(domain)


def combined_js_script(rules: list[dict]):
    """JS-правила (не скриптлеты) — одним скриптом, каждое со своей проверкой хоста и try;
    правило с синтаксической ошибкой выбрасывается заранее (node --check)."""
    parts, dropped = [], 0
    for r in rules:
        if not syntax_ok(js_script(r)["source"]):
            dropped += 1
            continue
        parts.append("if(ok(" + rule_json(r) + ")){try{\n" + r["b"] + "\n}catch(e){}}")
    if not parts:
        return None, dropped
    source = "(function(){\n" + MATCH_JS + "\n".join(parts) + "\n})();"
    return {"kind": "js", "rules": len(parts), "source": source}, dropped


def build_frames(sources: list[tuple[dict, str]], lib: Library) -> dict:
    """Скриптлеты для фреймов из FRAME_SOURCES: [(описание источника, текст)]."""
    rules: list[dict] = []
    untrusted = 0
    for meta, text in sources:
        for r in extract(text, meta.get("syntax", "adguard"), scope=frame_scope):
            if not meta.get("trusted"):
                # trusted-скриптлеты и JS — только из доверенных списков.
                if r["k"] == "j" or (r["k"] == "s" and r["a"][0].removeprefix("ubo-").startswith("trusted-")):
                    untrusted += 1
                    continue
            rules.append(r)
    rules = apply_exceptions(rules, lib)
    scripts = []
    main, missing = scriptlets_script([r for r in rules if r["k"] == "s"], lib)
    if main:
        if not syntax_ok(main["source"]):
            raise RuntimeError("скрипт скриптлетов для фреймов не прошёл проверку синтаксиса")
        scripts.append(main)
    js, dropped = combined_js_script([r for r in rules if r["k"] == "j"])
    if js:
        if not syntax_ok(js["source"]):
            raise RuntimeError("JS-правила для фреймов не прошли проверку синтаксиса")
        scripts.append(js)
    return {
        "scripts": scripts,
        "hosts": sorted({d for r in rules for d in r["d"]}),
        "rules": sum(x["rules"] for x in scripts),
        "missing": sorted(set(missing)),
        "droppedSyntax": dropped,
        "untrusted": untrusted,
    }


def build(rules_text: str, library_text: str, version: str, source_meta: dict,
          frame_sources: list | None = None) -> dict:
    lib = Library(library_text)
    rules = apply_exceptions(extract(rules_text), lib)
    scriptlet_rules = [r for r in rules if r["k"] == "s"]
    js_rules = [r for r in rules if r["k"] == "j"]
    scripts, dropped = [], 0
    main, missing = scriptlets_script(scriptlet_rules, lib)
    if main:
        if syntax_ok(main["source"]):
            scripts.append(main)
        else:
            raise RuntimeError("скрипт скриптлетов не прошёл проверку синтаксиса")
    for r in js_rules:
        s = js_script(r)
        if syntax_ok(s["source"]):
            scripts.append(s)
        else:
            dropped += 1
    hosts = sorted({d for r in rules for d in r["d"]})
    total = sum(s["rules"] for s in scripts)
    frames = build_frames(frame_sources, lib) if frame_sources else None
    extra = {}
    if frames and frames["scripts"]:
        extra = {"frameScripts": frames["scripts"], "frameHosts": frames["hosts"], "frameRules": frames["rules"],
                 "frameMissing": frames["missing"], "frameDroppedSyntax": frames["droppedSyntax"],
                 "frameUntrusted": frames["untrusted"]}
    return {
        **extra,
        "schema": 1,
        "version": version,
        "library": lib.version,
        "source": source_meta,
        "hosts": hosts,
        "rules": total,
        "scripts": scripts,
        "missing": sorted(set(missing)),
        "droppedSyntax": dropped,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description="Скриптлеты AdGuard для Kentik")
    ap.add_argument("out")
    ap.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M"))
    ap.add_argument("--manifest")
    ap.add_argument("--rules", help="файл списка вместо скачивания (для проверки)")
    ap.add_argument("--library", help="файл scriptlets.corelibs.json вместо скачивания")
    ap.add_argument("--frame-dir", help="папка с <id>.txt списков для фреймов вместо скачивания")
    ap.add_argument("--no-frames", action="store_true", help="без скриптлетов для фреймов")
    args = ap.parse_args()

    try:
        if args.rules:
            rules_url, rules_text = args.rules, open(args.rules, encoding="utf-8").read()
        else:
            rules_url, rules_text = fetch(RULES_URLS)
        if args.library:
            lib_url, lib_text = args.library, open(args.library, encoding="utf-8").read()
        else:
            lib_url, lib_text = fetch(LIBRARY_URLS)
    except RuntimeError as exc:
        print(f"::warning::скриптлеты AdGuard: источники не скачались ({exc})")
        return 0
    m = re.search(r"^!\s*Version:\s*(.+)$", rules_text, re.MULTILINE)
    meta = {"list": "AdGuard Base (Safari)", "listVersion": m.group(1).strip() if m else "", "listURL": rules_url,
            "libraryURL": lib_url}
    frame_sources = []
    for src in ([] if args.no_frames else FRAME_SOURCES):
        try:
            if src.get("file"):
                text = open(os.path.join(HERE, src["file"]), encoding="utf-8").read()
            elif args.frame_dir and os.path.exists(os.path.join(args.frame_dir, src["id"] + ".txt")):
                text = open(os.path.join(args.frame_dir, src["id"] + ".txt"), encoding="utf-8").read()
            else:
                _, text = fetch(src["urls"])
        except (RuntimeError, OSError) as exc:
            print(f"::warning::скриптлеты для фреймов: {src['id']} не скачался ({exc})")
            continue
        frame_sources.append((src, text))
        meta.setdefault("frameLists", []).append(src["title"])
    data = build(rules_text, lib_text, args.version, meta, frame_sources)
    if data.get("frameScripts"):
        size = sum(len(x["source"]) for x in data["frameScripts"])
        log(f"  для фреймов: правил {data['frameRules']}, хостов {len(data['frameHosts'])}, "
            f"{size / 1024:.0f} КБ; нет в библиотеке: {', '.join(data['frameMissing']) or '—'}; "
            f"недоверенных пропущено {data['frameUntrusted']}")
    log(f"скриптлеты AdGuard {data['version']}: правил {data['rules']}, скриптов {len(data['scripts'])}, "
        f"библиотека {data['library']}, список {meta['listVersion']}, хосты {', '.join(data['hosts'])}")
    if data["missing"]:
        log(f"  нет в библиотеке: {', '.join(data['missing'])}")
    if data["droppedSyntax"]:
        print(f"::warning::скриптлеты AdGuard: {data['droppedSyntax']} JS-правил с ошибкой синтаксиса выброшены")
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(args.out, "wb") as f:
        f.write(payload)
    log(f"  {args.out}: {len(payload) / 1024:.0f} КБ")

    if args.manifest:
        if data["rules"] < MIN_RULES:
            print(f"::warning::скриптлетов AdGuard всего {data['rules']} — в манифест не добавляю")
            return 0
        with open(args.manifest, encoding="utf-8") as f:
            manifest = json.load(f)
        manifest["adguard"] = {
            "file": os.path.basename(args.out),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "bytes": len(payload),
            "rules": data["rules"],
            "version": data["version"],
        }
        with open(args.manifest, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=1)
        log(f"  добавлено в {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
