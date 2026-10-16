#!/usr/bin/env bash
# Compile the LOJO Networks app for the iOS Simulator and capture demo screens.
# Demo host only: LOJO_SSH_PREVIEW=1 skips the real host seed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/App"
DERIVED="${DERIVED_DATA_PATH:-$REPO/.build/ios-simulator}"
OUT="${SIM_SHOT_DIR:-$REPO/.build/ios-simulator-shots}"
BUNDLE_ID="com.lojo.PrivateNetworks"

mkdir -p "$OUT"
bash "$REPO/scripts/ios-prepare.sh"

# A generic Simulator destination builds arm64 and x86_64. swift-atomics then
# fails to emit `_AtomicsShims` for the extra slice. Pin one arm64 iPhone.
DEVICE_LINE="$(xcrun simctl list devices available | grep -E 'iPhone' | head -1)"
UDID="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')"
if [[ -z "$UDID" || "$UDID" == "$DEVICE_LINE" ]]; then
  echo "No iPhone simulator: $DEVICE_LINE" >&2
  exit 1
fi
echo "Simulator $DEVICE_LINE"

xcodebuild \
  -project "$APP/LojoNetworks.xcodeproj" \
  -scheme LojoNetworks \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO \
  build

APP_PATH="$(find "$DERIVED" -type d -name 'LojoNetworks.app' -path '*iphonesimulator*' | head -1)"
if [[ -z "$APP_PATH" ]]; then
  echo "LojoNetworks.app was not produced" >&2
  exit 1
fi

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" "$APP_PATH"

shot() {
  local name="$1"
  shift
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  env "$@" xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null
  sleep 5
  xcrun simctl io "$UDID" screenshot "$OUT/$name.png"
  echo "wrote $OUT/$name.png"
}

shot reconnecting \
  SIMCTL_CHILD_LOJO_SCREEN=terminal \
  SIMCTL_CHILD_LOJO_SSH_SCREEN=reconnecting \
  SIMCTL_CHILD_LOJO_SSH_PREVIEW=1 \
  SIMCTL_CHILD_LOJO_SSH_REDACT=1

shot keep-sessions-alive \
  SIMCTL_CHILD_LOJO_SCREEN=terminal \
  SIMCTL_CHILD_LOJO_SSH_SCREEN=edit \
  SIMCTL_CHILD_LOJO_SSH_PREVIEW=1 \
  SIMCTL_CHILD_LOJO_SSH_REDACT=1

shot sessions \
  SIMCTL_CHILD_LOJO_SCREEN=terminal \
  SIMCTL_CHILD_LOJO_SSH_SCREEN=sessions \
  SIMCTL_CHILD_LOJO_SSH_PREVIEW=1 \
  SIMCTL_CHILD_LOJO_SSH_REDACT=1

shot scrollback \
  SIMCTL_CHILD_LOJO_SCREEN=terminal \
  SIMCTL_CHILD_LOJO_SSH_SCREEN=scrollback \
  SIMCTL_CHILD_LOJO_SSH_PREVIEW=1 \
  SIMCTL_CHILD_LOJO_SSH_FLOOD=400 \
  SIMCTL_CHILD_LOJO_SSH_REDACT=1

shot settings-build \
  SIMCTL_CHILD_LOJO_DEMO=1 \
  SIMCTL_CHILD_LOJO_SCREEN=settings

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
