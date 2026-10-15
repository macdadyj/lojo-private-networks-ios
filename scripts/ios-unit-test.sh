#!/usr/bin/env bash
# Run the iOS unit tests. TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
bash scripts/ios-prepare.sh
UDID="$(bash scripts/ios-sim-udid.sh)"
echo "Simulator ${UDID}"
xcodebuild test \
  -project App/LojoNetworks.xcodeproj \
  -scheme LojoNetworks \
  -destination "platform=iOS Simulator,id=${UDID}" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64
