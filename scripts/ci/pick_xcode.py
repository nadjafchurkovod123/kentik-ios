#!/usr/bin/env python3
"""Печатает путь к самому новому стабильному Xcode в /Applications (бета — только если
стабильных нет). Список всех найденных выводит в stderr."""
import glob
import os
import re
import sys


def main():
    found = []
    for path in glob.glob("/Applications/Xcode*.app"):
        if os.path.islink(path):
            continue
        name = os.path.basename(path)
        m = re.match(r"Xcode[_-]?(\d+(?:\.\d+)*)", name)
        if not m:
            continue
        version = tuple(int(x) for x in m.group(1).split("."))
        beta = bool(re.search(r"beta|rc|release.?candidate", name, re.I))
        found.append((not beta, version, path))
    for stable, version, path in sorted(found):
        print(f"  {path}{'' if stable else ' (бета)'}", file=sys.stderr)
    if not found:
        print("/Applications/Xcode.app")
        return
    print(max(found)[2])


if __name__ == "__main__":
    main()
