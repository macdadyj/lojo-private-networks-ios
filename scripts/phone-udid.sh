#!/usr/bin/env bash
# Prints the UDID of the one iPhone this repo deploys to, read from USB at run time (never commit it).
# The target is chosen by model, not by "first device", so a second phone on the hub is never touched:
#   LOJO_PHONE_MODEL  ProductType to accept (default iPhone12,1 = iPhone 11)
#   LOJO_UDID         explicit UDID; must still be on USB and be that model
# Exits non-zero, printing nothing on stdout, unless exactly one USB device matches.
set -euo pipefail

MODEL="${LOJO_PHONE_MODEL:-iPhone12,1}"
pymobiledevice3 usbmux list --usb 2>/dev/null | MODEL="$MODEL" WANT="${LOJO_UDID:-}" python3 -c '
import json, os, sys
devices = json.load(sys.stdin)
model, want = os.environ["MODEL"], os.environ["WANT"]
usb = [d for d in devices if d.get("ConnectionType", "USB") == "USB"]
match = [d for d in usb if d.get("ProductType") == model and (not want or d.get("Identifier") == want)]
others = sorted({d.get("ProductType", "?") for d in usb if d not in match})
if len(match) != 1:
    why = "no" if not match else f"{len(match)}"
    which = f"{model} matching LOJO_UDID" if want else model
    extra = f" (also on USB: {", ".join(others)})" if others else ""
    sys.stderr.write(f"{why} {which} on USB{extra}; refusing to pick a phone.\n")
    sys.exit(1)
if others:
    sys.stderr.write(f"using the {model}; ignoring {", ".join(others)} on USB\n")
print(match[0]["Identifier"])
'
