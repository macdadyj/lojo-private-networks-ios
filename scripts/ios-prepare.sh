#!/usr/bin/env bash
# Clone the pinned SwiftTerm checkout and generate LojoNetworks.xcodeproj.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/App"
SWIFTTERM_URL="https://github.com/migueldeicaza/SwiftTerm.git"
SWIFTTERM_REV="b1262db5b6bea699a8260a8c66999436c508ca56"

rm -rf "${APP}/Vendor/SwiftTerm"
mkdir -p "${APP}/Vendor"
git clone -q --filter=blob:none "${SWIFTTERM_URL}" "${APP}/Vendor/SwiftTerm"
git -C "${APP}/Vendor/SwiftTerm" -c advice.detachedHead=false checkout -q "${SWIFTTERM_REV}"
cp "${ROOT}/vendor/SwiftTerm.Package.swift" "${APP}/Vendor/SwiftTerm/Package.swift"

if ! command -v xcodegen >/dev/null; then
  brew install xcodegen
fi
(cd "${APP}" && xcodegen generate)
echo "${APP}/LojoNetworks.xcodeproj"
