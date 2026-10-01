#!/usr/bin/env bash
# Build, sign (free Apple ID), USB-install and launch LOJO Networks on the attached iPhone.
#   scripts/deploy-phone.sh                     dev build (debug) + sign + install + launch
#   scripts/deploy-phone.sh --build             unsigned compile check only
#   scripts/deploy-phone.sh --release [--build] release build: optimised, no DEBUG test hooks,
#                                               "Legacy HTTP over VPN" fallback off
# LOJO_LEGACY_HTTP_OVER_VPN=on|off overrides the fallback for either flavour.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="XTL-HG9HAYXW44.com.lojo.PrivateNetworks"

CONFIG=debug
BUILD_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --build) BUILD_ONLY=1 ;;
    --release) CONFIG=release ;;
    *) echo "usage: $0 [--release] [--build]" >&2; exit 2 ;;
  esac
done

case "${LOJO_LEGACY_HTTP_OVER_VPN:-}" in
  on) LEGACY=true ;;
  off) LEGACY=false ;;
  "") [[ "$CONFIG" == release ]] && LEGACY=false || LEGACY=true ;;
  *) echo "LOJO_LEGACY_HTTP_OVER_VPN must be on or off" >&2; exit 2 ;;
esac

# shellcheck disable=SC1091
source "$HOME/.config/ios-dev/env"
export PATH="$SWIFT_ROOT/usr/bin:$HOME/.local/bin:$PATH"
mkdir -p "$XTL_TMPDIR"

# Only the iPhone 11 (scripts/phone-udid.sh picks it by model; LOJO_UDID must also be one).
UDID=""
if [[ "$BUILD_ONLY" == 0 ]]; then
  UDID="$("$REPO/scripts/phone-udid.sh")" || {
    echo "Plug in the iPhone 11, unlock it and tap Trust (LOJO_PHONE_MODEL overrides the model)." >&2
    exit 1
  }
  export PYMOBILEDEVICE3_UDID="$UDID"
fi
# Two installs over one USB link corrupt each other; another checkout may be deploying.
if [[ "$BUILD_ONLY" == 0 ]] && pgrep -f 'xtool.* dev run' >/dev/null; then
  echo "Another 'xtool dev run' is installing to the phone. Wait for it to finish (pgrep -af xtool)." >&2
  exit 1
fi

BUILD_DIR="$("$REPO/scripts/sync-app.sh")"
cd "$BUILD_DIR"

# Only the build copy is edited; App/Info.plist in the repo keeps the dev value.
LEGACY="$LEGACY" python3 - <<'PY'
import os, plistlib
with open("Info.plist", "rb") as f:
    info = plistlib.load(f)
info["LOJOLegacyHTTPOverVPN"] = os.environ["LEGACY"] == "true"
with open("Info.plist", "wb") as f:
    plistlib.dump(info, f)
PY
echo "configuration: $CONFIG · Legacy HTTP over VPN: $([[ "$LEGACY" == true ]] && echo on || echo off)"

if [[ "$BUILD_ONLY" == 1 ]]; then
  exec xtool dev build -c "$CONFIG"
fi

xtool dev run -c "$CONFIG" --usb --udid "$UDID"
sleep 1
pymobiledevice3 developer core-device launch-application --userspace "$BUNDLE" '' >/dev/null
echo "installed + launched $BUNDLE"
