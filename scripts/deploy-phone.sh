#!/usr/bin/env bash
# Build, sign (free Apple ID), USB-install and launch LOJO Networks on the attached iPhone.
#   scripts/deploy-phone.sh           build + sign + install + launch
#   scripts/deploy-phone.sh --build   unsigned compile check only
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="XTL-HG9HAYXW44.com.lojo.PrivateNetworks"

# shellcheck disable=SC1091
source "$HOME/.config/ios-dev/env"
export PATH="$SWIFT_ROOT/usr/bin:$HOME/.local/bin:$PATH"
mkdir -p "$XTL_TMPDIR"

# The phone's UDID is a device identifier: read it from USB at run time, never commit it.
UDID="${LOJO_UDID:-$(pymobiledevice3 usbmux list --usb 2>/dev/null \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["Identifier"] if d else "")')}"
if [[ -z "$UDID" && "${1:-}" != "--build" ]]; then
  echo "No iPhone on USB. Plug it in, unlock it and tap Trust." >&2
  exit 1
fi

BUILD_DIR="$("$REPO/scripts/sync-app.sh")"
cd "$BUILD_DIR"

if [[ "${1:-}" == "--build" ]]; then
  exec xtool dev build
fi

xtool dev run --usb --udid "$UDID"
sleep 1
pymobiledevice3 developer core-device launch-application --userspace "$BUNDLE" '' >/dev/null
echo "installed + launched $BUNDLE"
