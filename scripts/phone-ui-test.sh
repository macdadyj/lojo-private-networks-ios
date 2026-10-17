#!/usr/bin/env bash
# Runs the iPhone UI tests (scrollback + every tap). TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
bash scripts/ios-prepare.sh
UDID="$(bash scripts/ios-sim-udid.sh)"
echo "Simulator ${UDID}"

mkdir -p build/phone-ui-screenshots
xcodebuild build-for-testing \
  -project App/LojoNetworks.xcodeproj \
  -scheme LojoNetworksUI \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -derivedDataPath build/DerivedDataUI \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO
APP_PATH="$(find build/DerivedDataUI -type d -name 'LojoNetworks.app' -path '*iphonesimulator*' | head -1)"
bash scripts/strip-simulator-broadcast.sh "${APP_PATH}" build/DerivedDataUI
run_phone() {
  xcodebuild test-without-building \
    -project App/LojoNetworks.xcodeproj \
    -scheme LojoNetworksUI \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -derivedDataPath build/DerivedDataUI \
    -resultBundlePath build/phone-ui-screenshots/LojoNetworksUI.xcresult \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=arm64 \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO
}

set +e
run_phone
status=$?
set -e
if [[ "${status}" -ne 0 ]]; then
  echo "Phone UI tests failed (status ${status}). Rebooting the simulator and trying once more." >&2
  xcrun simctl shutdown "${UDID}" || true
  sleep 2
  xcrun simctl boot "${UDID}" || true
  xcrun simctl bootstatus "${UDID}" -b || true
  rm -rf build/phone-ui-screenshots/LojoNetworksUI.xcresult
  run_phone
fi
mkdir -p build/phone-ui-screenshots
cp -f /tmp/lojo-remote-ui/*.png build/phone-ui-screenshots/ 2>/dev/null || true
