#!/usr/bin/env bash
# The simulator will not install an app that embeds the ReplayKit broadcast appex.
# Confirm the extension was built, then remove it from the simulator app bundle.
# Device archives do not call this script, so TestFlight still includes the extension.
set -euo pipefail

APP_PATH="${1:?simulator app path}"
DERIVED="${2:?derived data path}"

PLIST="$(find "${DERIVED}/Build/Products" -path '*/LojoBroadcast.appex/Info.plist' ! -path '*/LojoNetworks.app/*' | head -1)"
if [[ -z "${PLIST}" ]]; then
  echo "The ReplayKit broadcast extension was not built" >&2
  exit 1
fi
echo "Broadcast extension Info.plist:"
plutil -p "${PLIST}"
if ! plutil -p "${PLIST}" | grep -q 'com.apple.broadcast-services-upload'; then
  echo "The broadcast extension Info.plist has no ReplayKit extension point" >&2
  exit 1
fi
rm -rf "${APP_PATH}/PlugIns/LojoBroadcast.appex"
echo "Removed the broadcast appex from the simulator app. The device archive still embeds it."
