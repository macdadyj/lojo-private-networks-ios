#!/usr/bin/env bash
# Two simulators and the in-repo relay. One phone runs iPhone Remote Controller.
# The other is the controller. TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
PORT="${PORT:-8791}"
CODE="ci-remote"
DERIVED="${ROOT}/build/DerivedDataRemote"
SHOTS="${ROOT}/build/remote-pair-screenshots"
LOG="${ROOT}/build/remote-pair.log"
mkdir -p "${SHOTS}" "$(dirname "${LOG}")"

RELAY_PID=""
DEVICE_UDID=""
CONTROLLER_UDID=""
cleanup() {
  if [[ -n "${RELAY_PID}" ]]; then
    kill "${RELAY_PID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${DEVICE_UDID}" ]]; then
    xcrun simctl io "${DEVICE_UDID}" screenshot "${SHOTS}/spare-iphone.png" >/dev/null 2>&1 || true
    xcrun simctl delete "${DEVICE_UDID}" >/dev/null 2>&1 || true
  fi
  if [[ -n "${CONTROLLER_UDID}" ]]; then
    xcrun simctl io "${CONTROLLER_UDID}" screenshot "${SHOTS}/controller.png" >/dev/null 2>&1 || true
  fi
  mkdir -p "${SHOTS}"
  cp -f /tmp/lojo-remote-ui/*.png "${SHOTS}/" 2>/dev/null || true
  rm -f /tmp/lojo-remote-pair
}
trap cleanup EXIT

BIND=127.0.0.1 PORT="${PORT}" ONLINE_MS=12000 node "${ROOT}/relay/server.js" >/tmp/lojo-remote-relay.log 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:${PORT}/health" | grep -q lojo-remote-relay; then
    break
  fi
  sleep 0.2
done
curl -sf "http://127.0.0.1:${PORT}/health" | grep -q lojo-remote-relay

bash scripts/ios-prepare.sh
# Clone an already-compatible iPhone. Creating from the last device type fails
# when that type does not match the newest runtime ("Incompatible device").
CONTROLLER_UDID="$(bash scripts/ios-sim-udid.sh)"
DEVICE_UDID="$(xcrun simctl clone "${CONTROLLER_UDID}" "LOJO Spare iPhone")"
echo "Spare ${DEVICE_UDID}"
echo "Controller ${CONTROLLER_UDID}"

xcodebuild build-for-testing \
  -project App/LojoNetworks.xcodeproj \
  -scheme LojoNetworksUI \
  -destination "platform=iOS Simulator,id=${CONTROLLER_UDID}" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -derivedDataPath "${DERIVED}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO

APP_PATH="$(find "${DERIVED}" -type d -name 'LojoNetworks.app' -path '*iphonesimulator*' | head -1)"
if [[ -z "${APP_PATH}" ]]; then
  echo "LojoNetworks.app was not produced" >&2
  exit 1
fi
xcrun simctl boot "${DEVICE_UDID}" || true
xcrun simctl bootstatus "${DEVICE_UDID}" -b
xcrun simctl install "${DEVICE_UDID}" "${APP_PATH}"
SIMCTL_CHILD_LOJO_SCREEN=device \
SIMCTL_CHILD_LOJO_REMOTE_ROLE=device \
SIMCTL_CHILD_LOJO_RELAY_URL="http://127.0.0.1:${PORT}" \
SIMCTL_CHILD_LOJO_NETWORK_CODE="${CODE}" \
SIMCTL_CHILD_LOJO_REMOTE_NAME="Spare iPhone" \
SIMCTL_CHILD_LOJO_REMOTE_BATTERY=81 \
SIMCTL_CHILD_LOJO_REMOTE_NOW=20:30 \
SIMCTL_CHILD_LOJO_REMOTE_PREVIEW_FRAME=1 \
SIMCTL_CHILD_LOJO_DEMO=0 \
  xcrun simctl launch "${DEVICE_UDID}" com.lojo.PrivateNetworks

registered=0
for _ in $(seq 1 40); do
  if curl -sf -H "X-Lojo-Network: ${CODE}" "http://127.0.0.1:${PORT}/v1/phones" | grep -q "Spare iPhone"; then
    registered=1
    break
  fi
  sleep 1
done
if [[ "${registered}" != 1 ]]; then
  echo "The spare iPhone did not register with the relay." >&2
  cat /tmp/lojo-remote-relay.log >&2 || true
  exit 1
fi

touch /tmp/lojo-remote-pair
export LOJO_REMOTE_PAIR=1
set +e
xcodebuild test-without-building \
  -project App/LojoNetworks.xcodeproj \
  -scheme LojoNetworksUI \
  -destination "platform=iOS Simulator,id=${CONTROLLER_UDID}" \
  -derivedDataPath "${DERIVED}" \
  -resultBundlePath "${SHOTS}/RemotePair.xcresult" \
  -only-testing:LojoNetworksUITests/RemotePairUITests \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="-" \
  DEVELOPMENT_TEAM="" \
  ONLY_ACTIVE_ARCH=YES \
  ARCHS=arm64 \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO | tee "${LOG}"
status=${PIPESTATUS[0]}
set -e
if [[ "${status}" -ne 0 ]]; then
  echo "Controller UI test failed." >&2
  exit "${status}"
fi
if ! grep -E "testControllerSeesDeviceOverTheRelay.*passed" "${LOG}" >/dev/null; then
  echo "The pair test did not pass. A skip does not count." >&2
  exit 1
fi

python3 - "${PORT}" "${CODE}" <<'PY'
import json, sys, urllib.request
port, code = sys.argv[1], sys.argv[2]
def get(path):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        headers={"X-Lojo-Network": code},
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return response.status, response.read()
status, body = get("/v1/phones")
phones = json.loads(body)["phones"]
if len(phones) != 1 or phones[0]["name"] != "Spare iPhone":
    raise SystemExit("relay phone list was not the spare iPhone")
phone = phones[0]
if not phone.get("online"):
    raise SystemExit("spare iPhone was offline after the controller test")
if phone.get("batteryPercent") != 81:
    raise SystemExit("battery was not reported")
schedules = phone.get("schedules") or []
if not any(item.get("soundID") == "white-noise" and item.get("startMinutes") == 1200 and item.get("stopMinutes") == 360 for item in schedules):
    raise SystemExit("overnight white noise schedule was not stored on the relay")
playback = phone.get("playback") or {}
if not playback.get("playing") or playback.get("soundID") != "white-noise":
    raise SystemExit("spare iPhone was not playing white noise")
frame_status, frame = get(f"/v1/phones/{phone['id']}/screen")
if frame_status != 200 or not frame.startswith(b"\xff\xd8"):
    raise SystemExit("live screen frame was not a JPEG on the relay")
print("relay pair check ok")
PY
