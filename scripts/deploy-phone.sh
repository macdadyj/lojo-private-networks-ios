#!/usr/bin/env bash
# Build, sign (free Apple ID), USB-install and launch LOJO Networks on the attached iPhone.
#   scripts/deploy-phone.sh           build + sign + install + launch
#   scripts/deploy-phone.sh --build   unsigned compile check only
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
UDID="${LOJO_UDID:-00008030-001A4D340A93402E}"
BUNDLE="XTL-HG9HAYXW44.com.lojo.PrivateNetworks"

# shellcheck disable=SC1091
source "$HOME/.config/ios-dev/env"
export PATH="$SWIFT_ROOT/usr/bin:$HOME/.local/bin:$PATH"
mkdir -p "$XTL_TMPDIR"

BUILD_DIR="$("$REPO/scripts/sync-app.sh")"
cd "$BUILD_DIR"

if [[ "${1:-}" == "--build" ]]; then
  exec xtool dev build
fi

xtool dev run --usb --udid "$UDID"
sleep 1
pymobiledevice3 developer core-device launch-application --userspace "$BUNDLE" '' >/dev/null
echo "installed + launched $BUNDLE"
