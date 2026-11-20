#!/usr/bin/env python3
"""Собирает Sources/Resources/ad_hosts.json — набор рекламных, попандерных и вредоносных хостов.

Использование: build_ad_hosts.py <файл-вывода> [--version yyyyMMddHHmm] [--manifest manifest.json]

С --manifest файл ещё и записывается в манифест списков фильтров (ключ "hosts": имя файла,
sha256, размер, число хостов) — так набор публикуется в релиз «lists» вместе со списками и
приложение обновляет его раз в сутки, а не только с новой сборкой IPA. Если источники не
скачались (в наборе почти ничего), в манифест он не попадает.

Набор нужен защите от всплывающих окон и перенаправлений (Guard/AdHosts.swift): переход
главного фрейма без касания пользователя на такой хост отменяется, новое окно на такой хост
не открывается. Файл общий с блокировщиком рекламы: формат простой —
{"version": "...", "count": N, "sources": {...}, "hosts": ["example.com", ...]}.
Хост в списке означает «сам хост и все его поддомены».

Источники (каждый необязателен — если сеть подвела, берём то, что скачалось):
  * Peter Lowe's Ad and tracking server list (hosts-формат);
  * AdGuard DNS filter (правила ||host^, исключения @@||host^);
  * EasyList adservers popup (правила ||host^$popup — сети попандеров);
  * uBlock Origin badware (вредоносные и мошеннические сайты);
  * uBlock Origin filters — только правила ||host^$popup без привязки к сайту.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import sys
import urllib.request

SOURCES = {
    "peter-lowe": ("hosts",
                   "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=hosts&showintro=0&mimetype=plaintext"),
    "adguard-dns": ("abp", "https://adguardteam.github.io/AdGuardSDNSFilter/Filters/filter.txt"),
    "easylist-popups": ("abp-popup",
                        "https://raw.githubusercontent.com/easylist/easylist/master/easylist/easylist_adservers_popup.txt"),
    "ubo-badware": ("abp", "https://ublockorigin.github.io/uAssets/filters/badware.txt"),
    "ubo-popups": ("abp-popup", "https://ublockorigin.github.io/uAssets/filters/filters.txt"),
}

# Известные сети попандеров — на случай, если ни один источник не скачался.
SEED = [
    "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "adsterra.com",
    "exoclick.com", "juicyads.com", "adcash.com", "hilltopads.net", "clickadu.com",
    "onclickads.net", "onclkds.com", "trafficjunky.net", "admaven.com", "ad-maven.com",
    "monetag.com", "richads.com", "clickaine.com", "galaksion.com", "popunder.net",
    "adspyglass.com", "realsrv.com", "tsyndicate.com", "doubleclick.net",
    "googlesyndication.com", "googleadservices.com",
]

# Никогда не попадают в набор сами по себе (поддомены вроде adservice.google.com — могут):
# крупные сайты и входы через OAuth, без которых браузер бесполезен.
NEVER = {
    "google.com", "youtube.com", "googleapis.com", "gstatic.com", "googlevideo.com",
    "accounts.google.com", "apple.com", "icloud.com", "appleid.apple.com", "yandex.ru",
    "yandex.com", "ya.ru", "vk.com", "vk.ru", "mail.ru", "ok.ru", "t.me", "telegram.org",
    "github.com", "githubusercontent.com", "microsoft.com", "live.com", "microsoftonline.com",
    "cloudflare.com", "facebook.com", "instagram.com", "x.com", "twitter.com", "twimg.com",
    "wikipedia.org", "amazon.com", "amazonaws.com", "cloudfront.net", "akamaihd.net",
    "jsdelivr.net", "unpkg.com", "cdnjs.cloudflare.com", "gosuslugi.ru", "sberbank.ru",
    "tbank.ru", "tinkoff.ru", "paypal.com", "stripe.com", "whatsapp.com", "reddit.com",
    "twitch.tv", "discord.com", "localhost", "t.co", "bit.ly", "goo.gl", "youtu.be",
    "lnkd.in", "vk.cc", "clck.ru",
}

HOST_RE = re.compile(r"^(?=.{4,253}$)([a-z0-9_](?:[a-z0-9_-]{0,61}[a-z0-9_])?\.)+[a-z][a-z0-9-]{1,62}$")
ABP_RE = re.compile(r"^\|\|([a-z0-9._-]+)\^(?:\$(.*))?$")
# Опции, при которых правило всё ещё значит «весь хост плохой».
PLAIN_OPTS = {"", "important", "third-party", "3p", "all", "doc", "document", "popup"}


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0 (KentikCI)"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def valid(host):
    return bool(HOST_RE.match(host)) and host not in NEVER


def parse(kind, text):
    hosts, exceptions = set(), set()
    for raw in text.splitlines():
        line = raw.strip().lower()
        if not line or line[0] in "!#[":
            continue
        if kind == "hosts":
            parts = line.split()
            if len(parts) >= 2 and parts[0] in ("127.0.0.1", "0.0.0.0"):
                hosts.add(parts[1].rstrip("."))
            continue
        exception = line.startswith("@@")
        if exception:
            line = line[2:]
        m = ABP_RE.match(line)
        if not m:
            continue
        host, opts = m.group(1).rstrip("."), m.group(2) or ""
        options = {o.strip() for o in opts.split(",")} if opts else {""}
        if any(o.startswith("domain=") or o.startswith("from=") or o.startswith("denyallow=") for o in options):
            continue
        if kind == "abp-popup" and "popup" not in options:
            continue
        if not options <= PLAIN_OPTS:
            continue
        (exceptions if exception else hosts).add(host)
    return hosts, exceptions


def compact(hosts):
    """Убирает хосты, родитель которых уже в наборе (проверка идёт по суффиксам)."""
    result = set()
    for host in hosts:
        labels = host.split(".")
        if any(".".join(labels[i:]) in hosts for i in range(1, len(labels) - 1)):
            continue
        result.add(host)
    return result


# Меньше — значит источники не скачались: такой набор не публикуем (приложение оставит прежний).
MIN_PUBLISHED_HOSTS = 2000


def main():
    ap = argparse.ArgumentParser(description="Набор рекламных хостов Kentik")
    ap.add_argument("out")
    ap.add_argument("--version", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M"))
    ap.add_argument("--manifest")
    args = ap.parse_args()
    out = args.out
    hosts, exceptions, counts = set(SEED), set(), {}
    for name, (kind, url) in SOURCES.items():
        try:
            found, excluded = parse(kind, fetch(url))
        except Exception as error:  # noqa: BLE001 — любой сбой сети не должен ронять сборку
            print(f"::warning::{name}: не скачался ({error})")
            counts[name] = 0
            continue
        counts[name] = len(found)
        hosts |= found
        exceptions |= excluded
        print(f"{name}: {len(found)} хостов, исключений {len(excluded)}")
    hosts = {h for h in hosts - exceptions if valid(h)}
    hosts = sorted(compact(hosts))
    data = {
        # Цифры yyyyMMddHHmm, как у списков фильтров: приложение берёт более свежий набор
        # из встроенного и скачанного.
        "version": args.version,
        "count": len(hosts),
        "sources": counts,
        "hosts": hosts,
    }
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    with open(out, "wb") as f:
        f.write(payload)
    print(f"итого: {len(hosts)} хостов: {out}")

    if args.manifest:
        if len(hosts) < MIN_PUBLISHED_HOSTS:
            print(f"::warning::в наборе всего {len(hosts)} хостов — в манифест не добавляю")
            return 0
        with open(args.manifest, encoding="utf-8") as f:
            manifest = json.load(f)
        manifest["hosts"] = {
            "file": os.path.basename(out),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "bytes": len(payload),
            "count": len(hosts),
            "version": args.version,
        }
        with open(args.manifest, "w", encoding="utf-8") as f:
            json.dump(manifest, f, ensure_ascii=False, indent=1)
        print(f"набор хостов добавлен в {args.manifest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
