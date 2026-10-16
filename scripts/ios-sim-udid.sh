#!/usr/bin/env bash
# Print one available arm64 iPhone simulator UDID.
set -euo pipefail
python3 - <<'PY'
import json, subprocess
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True)
data = json.loads(raw)
chosen = ""
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if name.startswith("iPhone") and device.get("isAvailable", True):
            chosen = device["udid"]
if not chosen:
    raise SystemExit("No available iPhone simulator")
print(chosen)
PY
