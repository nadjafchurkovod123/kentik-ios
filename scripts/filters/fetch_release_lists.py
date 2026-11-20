#!/usr/bin/env python3
"""Запасной путь: берёт уже собранные списки из релиза «lists» (manifest.json + файлы),
проверяет sha256 и кладёт в папку вывода. Нужен, если источники или конвертер недоступны.

Использование: fetch_release_lists.py --out <папка> [--base <URL релиза>]
"""
import argparse
import hashlib
import json
import os
import sys
import urllib.request

BASE = "https://github.com/nadjafchurkovod123/kentik-ios/releases/download/lists"


def get(url: str) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "KentikFilterBuilder/1.0"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.read()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--base", default=BASE)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    manifest_raw = get(f"{args.base}/manifest.json")
    manifest = json.loads(manifest_raw)
    if manifest.get("schema") != 1:
        raise SystemExit("неизвестная схема манифеста")
    for entry in manifest["lists"]:
        data = get(f"{args.base}/{entry['file']}")
        digest = hashlib.sha256(data).hexdigest()
        if digest != entry["sha256"]:
            raise SystemExit(f"sha256 не совпал: {entry['file']}")
        with open(os.path.join(args.out, entry["file"]), "wb") as f:
            f.write(data)
        print(f"  {entry['file']}: {entry['rules']} правил", flush=True)
    hosts = manifest.get("hosts")
    if hosts:
        data = get(f"{args.base}/{hosts['file']}")
        if hashlib.sha256(data).hexdigest() == hosts["sha256"]:
            with open(os.path.join(args.out, hosts["file"]), "wb") as f:
                f.write(data)
            print(f"  {hosts['file']}: {hosts.get('count')} хостов", flush=True)
    with open(os.path.join(args.out, "manifest.json"), "wb") as f:
        f.write(manifest_raw)
    print(f"Списки из релиза, версия {manifest['version']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
