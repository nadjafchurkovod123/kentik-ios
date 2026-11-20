#!/usr/bin/env python3
"""Достаёт все вложения-снимки XCUITest из .xcresult в PNG-файлы с понятными именами.

Использование: export_screenshots.py <TestResults.xcresult> <папка-вывода>

Работает через `xcrun xcresulttool export attachments` (Xcode 16+). Имена берутся из
manifest.json: <тест>__<имя вложения>.png. Не-PNG картинки (HEIC/JPEG) переводятся в PNG
через sips.
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

IMAGE_EXT = {".png", ".jpg", ".jpeg", ".heic", ".heif", ".tiff"}


def safe(name: str) -> str:
    name = re.sub(r"[^\w.\-]+", "_", name, flags=re.UNICODE).strip("._")
    return name or "attachment"


def to_png(src: str, dst: str) -> None:
    if src.lower().endswith(".png"):
        shutil.copyfile(src, dst)
        return
    subprocess.run(["sips", "-s", "format", "png", src, "--out", dst], check=True,
                   stdout=subprocess.DEVNULL)


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__)
        return 2
    xcresult, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    if not os.path.exists(xcresult):
        print(f"нет {xcresult} — тесты не запускались")
        return 0

    raw = tempfile.mkdtemp(prefix="attachments-")
    subprocess.run(["xcrun", "xcresulttool", "export", "attachments",
                    "--path", xcresult, "--output-path", raw], check=True)

    manifest_path = os.path.join(raw, "manifest.json")
    exported = 0
    used = set()
    if os.path.exists(manifest_path):
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
        for test in manifest:
            test_id = test.get("testIdentifier", "test")
            test_name = safe(test_id.split("/")[-1].replace("()", ""))
            for att in test.get("attachments", []):
                file_name = att.get("exportedFileName")
                if not file_name:
                    continue
                src = os.path.join(raw, file_name)
                if os.path.splitext(file_name)[1].lower() not in IMAGE_EXT or not os.path.exists(src):
                    continue
                human = att.get("suggestedHumanReadableName") or file_name
                human = os.path.splitext(human)[0]
                # Xcode дописывает к имени "_0_<UUID>" — убираем для читаемости.
                human = re.sub(r"_\d+_[0-9A-Fa-f-]{36}$", "", human)
                base = f"{test_name}__{safe(human)}"
                name, n = base, 1
                while name in used:
                    n += 1
                    name = f"{base}_{n}"
                used.add(name)
                to_png(src, os.path.join(out_dir, name + ".png"))
                exported += 1
    else:
        for file_name in sorted(os.listdir(raw)):
            if os.path.splitext(file_name)[1].lower() in IMAGE_EXT:
                to_png(os.path.join(raw, file_name),
                       os.path.join(out_dir, safe(os.path.splitext(file_name)[0]) + ".png"))
                exported += 1

    print(f"снимков экрана: {exported}")
    for name in sorted(os.listdir(out_dir)):
        print("  ", name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
