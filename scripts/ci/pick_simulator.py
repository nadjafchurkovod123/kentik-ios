#!/usr/bin/env python3
"""Выбирает самый новый доступный iPhone-симулятор для выбранного Xcode.

Печатает выбор и дописывает SIM_UDID / SIM_NAME / SIM_OS в $GITHUB_ENV (если задан).
Если для новейшей среды iOS нет ни одного iPhone, создаёт его.
"""
import json
import os
import re
import subprocess
import sys


def simctl_json(*args):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *args]))


def version_key(text):
    return tuple(int(x) for x in re.findall(r"\d+", text))


def phone_score(name):
    m = re.search(r"iPhone (\d+)", name)
    number = int(m.group(1)) if m else 0
    return (number, name.endswith(" Pro"), "Max" not in name, "Plus" not in name)


def main():
    runtimes = [
        r for r in simctl_json("runtimes")["runtimes"]
        if r.get("isAvailable", True)
        and (r.get("platform") == "iOS" or ".iOS-" in r.get("identifier", ""))
    ]
    runtimes.sort(key=lambda r: version_key(r["version"]), reverse=True)
    if not runtimes:
        sys.exit("нет ни одной среды iOS-симулятора")
    print("Среды iOS:", ", ".join(r["version"] for r in runtimes))

    devices = simctl_json("devices", "available")["devices"]
    chosen = None
    for runtime in runtimes:
        phones = [d for d in devices.get(runtime["identifier"], []) if d["name"].startswith("iPhone")]
        if phones:
            phones.sort(key=lambda d: phone_score(d["name"]), reverse=True)
            chosen = (runtime, phones[0])
            break
        # Для новейшей среды устройств нет — создаём.
        types = [t for t in runtime.get("supportedDeviceTypes", []) if t.get("name", "").startswith("iPhone")]
        if types:
            types.sort(key=lambda t: phone_score(t["name"]), reverse=True)
            udid = subprocess.check_output(
                ["xcrun", "simctl", "create", "Kentik " + types[0]["name"],
                 types[0]["identifier"], runtime["identifier"]], text=True).strip()
            chosen = (runtime, {"name": types[0]["name"], "udid": udid})
            break
    if not chosen:
        sys.exit("не найден iPhone-симулятор")

    runtime, device = chosen
    print(f"Выбран симулятор: {device['name']} ({device['udid']}), iOS {runtime['version']} "
          f"[{runtime['identifier']}]")
    env = os.environ.get("GITHUB_ENV")
    if env:
        with open(env, "a", encoding="utf-8") as f:
            f.write(f"SIM_UDID={device['udid']}\nSIM_NAME={device['name']}\nSIM_OS={runtime['version']}\n")


if __name__ == "__main__":
    main()
