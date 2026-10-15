#!/usr/bin/env bash
# Runs the iPhone UI tests (scrollback + every tap). TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
bash scripts/ios-prepare.sh
UDID="$(bash scripts/ios-sim-udid.sh)"
echo "Simulator ${UDID}"

mkdir -p build/phone-ui-screenshots
run_phone() {
  xcodebuild test \
    -project App/LojoNetworks.xcodeproj \
    -scheme LojoNetworksUI \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -derivedDataPath build/DerivedDataUI \
    -resultBundlePath build/phone-ui-screenshots/LojoNetworksUI.xcresult \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=arm64
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
