#!/usr/bin/env bash
# Compile the LOJO Networks app for the iOS Simulator and capture three debug screens.
# Demo host only: LOJO_SSH_PREVIEW=1 skips the real host seed.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/App"
DERIVED="${DERIVED_DATA_PATH:-$REPO/.build/ios-simulator}"
OUT="${SIM_SHOT_DIR:-$REPO/.build/ios-simulator-shots}"
SWIFTTERM_URL="https://github.com/migueldeicaza/SwiftTerm.git"
SWIFTTERM_REV="b1262db5b6bea699a8260a8c66999436c508ca56"
BUNDLE_ID="com.lojo.PrivateNetworks"

mkdir -p "$OUT"
rm -rf "$APP/Vendor/SwiftTerm"
mkdir -p "$APP/Vendor"
git clone -q --filter=blob:none "$SWIFTTERM_URL" "$APP/Vendor/SwiftTerm"
git -C "$APP/Vendor/SwiftTerm" -c advice.detachedHead=false checkout -q "$SWIFTTERM_REV"
cp "$REPO/vendor/SwiftTerm.Package.swift" "$APP/Vendor/SwiftTerm/Package.swift"

if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi
(cd "$APP" && xcodegen generate)

xcodebuild \
  -project "$APP/LojoNetworks.xcodeproj" \
  -scheme LojoNetworks \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

APP_PATH="$(find "$DERIVED" -type d -name 'LojoNetworks.app' -path '*iphonesimulator*' | head -1)"
if [[ -z "$APP_PATH" ]]; then
  echo "LojoNetworks.app was not produced" >&2
  exit 1
fi

DEVICE_LINE="$(xcrun simctl list devices available | grep -E 'iPhone' | head -1)"
UDID="$(printf '%s\n' "$DEVICE_LINE" | sed -E 's/.*\(([A-F0-9-]+)\).*/\1/')"
if [[ -z "$UDID" || "$UDID" == "$DEVICE_LINE" ]]; then
  echo "No iPhone simulator: $DEVICE_LINE" >&2
  exit 1
fi
echo "Simulator $DEVICE_LINE"

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

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
