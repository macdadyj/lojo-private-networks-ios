#!/usr/bin/env bash
# Launch the app on the iPhone straight into one screen and save a screenshot.
#   scripts/phone-shot.sh OUT.png [KEY=VALUE ...]
# Keys are the QA launch variables from docs/design.md, e.g.
#   scripts/phone-shot.sh docs/screenshots/01-home-live.png LOJO_DEMO=0 LOJO_SCREEN=home
#   scripts/phone-shot.sh /tmp/detail.png LOJO_DEMO=1 LOJO_SCREEN=detail LOJO_DEVICE=north-gate
# Wait time before the capture: LOJO_SHOT_WAIT (seconds, default 6).
set -euo pipefail

OUT="$1"; shift
BUNDLE="XTL-HG9HAYXW44.com.lojo.PrivateNetworks"
WAIT="${LOJO_SHOT_WAIT:-6}"

args=()
for kv in "$@"; do args+=(--env "$kv"); done

# Same phone as deploy-phone.sh; the userspace tunnel reads the target from this variable.
PYMOBILEDEVICE3_UDID="$("$(dirname "$0")/phone-udid.sh")"
export PYMOBILEDEVICE3_UDID

pymobiledevice3 developer core-device launch-application --userspace --kill-existing \
  "${args[@]}" "$BUNDLE" '' >/dev/null
sleep "$WAIT"
mkdir -p "$(dirname "$OUT")"
pymobiledevice3 developer core-device screen-capture screenshot --userspace "$OUT" 2>&1 | tail -1
