#!/usr/bin/env python3
"""Добавляет версию Kentik в источник AltStore (altstore/source.json).

Использование:
  altstore_source.py --source altstore/source.json --ipa build/Kentik.ipa \
      --version 1.0.0 --build 42 --url https://…/Kentik.ipa --date 2026-11-20T12:00:00Z \
      [--notes "что нового"]

Формат — источник AltStore 2 (apps[].versions) с дублированием полей верхнего уровня
(version, downloadURL, size, …) для старых AltStore 1.x. Разрешения (appPermissions)
берутся из Info.plist самого IPA: AltStore 2 сверяет их с приложением и откажется ставить,
если в приложении есть необъявленные.
"""
import argparse
import json
import os
import plistlib
import sys
import zipfile

BUNDLE_ID = "io.kentik.browser"


def read_info_plist(ipa: str) -> dict:
    with zipfile.ZipFile(ipa) as z:
        for name in z.namelist():
            parts = name.split("/")
            if len(parts) == 3 and parts[0] == "Payload" and parts[1].endswith(".app") and parts[2] == "Info.plist":
                return plistlib.loads(z.read(name))
    raise SystemExit("в IPA нет Payload/*.app/Info.plist")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    ap.add_argument("--ipa", required=True)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--date", required=True)
    ap.add_argument("--notes", default="")
    args = ap.parse_args()

    info = read_info_plist(args.ipa)
    if info.get("CFBundleIdentifier") != BUNDLE_ID:
        raise SystemExit(f"bundle id {info.get('CFBundleIdentifier')!r}, ждали {BUNDLE_ID}")
    if info.get("CFBundleShortVersionString") != args.version:
        raise SystemExit(f"версия в IPA {info.get('CFBundleShortVersionString')!r} ≠ тегу {args.version!r}")
    if str(info.get("CFBundleVersion")) != str(args.build):
        raise SystemExit(f"сборка в IPA {info.get('CFBundleVersion')!r} ≠ {args.build!r}")
    min_os = info.get("MinimumOSVersion", "17.0")
    privacy = {k: v for k, v in sorted(info.items()) if k.startswith("NS") and k.endswith("UsageDescription")}

    with open(args.source, encoding="utf-8") as f:
        source = json.load(f)
    app = next(a for a in source["apps"] if a["bundleIdentifier"] == BUNDLE_ID)

    entry = {
        "version": args.version,
        "buildVersion": str(args.build),
        "date": args.date,
        "localizedDescription": args.notes or f"Kentik {args.version}",
        "downloadURL": args.url,
        "size": os.path.getsize(args.ipa),
        "minOSVersion": min_os,
    }
    versions = [v for v in app.get("versions", []) if v.get("version") != args.version]
    versions.insert(0, entry)
    app["versions"] = versions
    app["appPermissions"] = {"entitlements": [], "privacy": privacy}
    # Поля AltStore 1.x (последняя версия).
    app["version"] = entry["version"]
    app["versionDate"] = entry["date"]
    app["versionDescription"] = entry["localizedDescription"]
    app["downloadURL"] = entry["downloadURL"]
    app["size"] = entry["size"]

    with open(args.source, "w", encoding="utf-8", newline="\n") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(json.dumps(entry, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
