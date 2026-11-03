#!/usr/bin/env bash
# Two simulators and the in-repo relay. One phone runs iPhone Remote Controller.
# The other is the controller. TestFlight waits for this script.
set -euo pipefail

SPARE_SIM_NAME="LOJO Spare iPhone"

is_simulator_udid() {
  [[ "$1" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]
}

# A failed clone can leave a device allocated with our spare name, or stuck
# in the Creating state with no usable UDID on stdout. Delete those before
# the next attempt. Never delete the controller we cloned from.
delete_half_created_simulators() {
  local leaked="${1:-}"
  local udid listed
  echo "Cleaning up half-created simulators" >&2
  if is_simulator_udid "${leaked}" && [[ "${leaked}" != "${CONTROLLER_UDID}" ]]; then
    echo "Deleting simulator left by the failed clone: ${leaked}" >&2
    xcrun simctl delete "${leaked}" >/dev/null 2>&1 || true
  fi
  listed="$(python3 - "${CONTROLLER_UDID}" "${SPARE_SIM_NAME}" <<'PY'
import json, subprocess, sys
controller, spare_name = sys.argv[1], sys.argv[2]
try:
    raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "-j"], text=True)
    data = json.loads(raw)
except (OSError, subprocess.CalledProcessError, json.JSONDecodeError):
    raise SystemExit(0)
for devices in data.get("devices", {}).values():
    if not isinstance(devices, list):
        continue
    for device in devices:
        if not isinstance(device, dict):
            continue
        udid = device.get("udid") or ""
        if not udid or udid == controller:
            continue
        if device.get("name") == spare_name or device.get("state") == "Creating":
            print(udid)
PY
)" || true
  while IFS= read -r udid; do
    [[ -z "${udid}" ]] && continue
    [[ "${udid}" == "${CONTROLLER_UDID}" ]] && continue
    echo "Deleting half-created simulator ${udid}" >&2
    xcrun simctl delete "${udid}" >/dev/null 2>&1 || true
  done <<< "${listed}"
}

# CoreSimulator flakes with NSPOSIXErrorDomain 22: the clone is allocated and
# stuck in creation. Three attempts, backoff 5s, 15s, then 30s. The 30s step
# is the wait for a further try. After the third failure the gate exits.
clone_spare_iphone() {
  local attempt=0 delay clone_status leaked err_file cloned
  echo "Cloning ${SPARE_SIM_NAME} from ${CONTROLLER_UDID}" >&2
  for delay in 5 15 30; do
    attempt=$((attempt + 1))
    echo "simctl clone attempt ${attempt}/3" >&2
    err_file="$(mktemp)"
    set +e
    cloned="$(xcrun simctl clone "${CONTROLLER_UDID}" "${SPARE_SIM_NAME}" 2>"${err_file}")"
    clone_status=$?
    set -e
    cloned="$(printf '%s' "${cloned}" | tr -d '[:space:]')"
    if [[ -s "${err_file}" ]]; then
      cat "${err_file}" >&2
    fi
    rm -f "${err_file}"
    if [[ "${clone_status}" -eq 0 ]] && is_simulator_udid "${cloned}"; then
      DEVICE_UDID="${cloned}"
      return 0
    fi
    echo "simctl clone attempt ${attempt}/3 failed (exit ${clone_status})" >&2
    leaked="${cloned}"
    DEVICE_UDID=""
    delete_half_created_simulators "${leaked}"
    if [[ "${attempt}" -eq 3 ]]; then
      echo "simctl clone failed after 3 attempts" >&2
      return 1
    fi
    echo "Waiting ${delay}s before simctl clone attempt $((attempt + 1))/3" >&2
    sleep "${delay}"
    delete_half_created_simulators ""
  done
  echo "simctl clone failed after 3 attempts" >&2
  return 1
}

self_test_clone_retry() {
  local tmp bin
  tmp="$(mktemp -d)"
  bin="${tmp}/bin"
  mkdir -p "${bin}"
  cat > "${bin}/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${MOCK_DIR}/calls"
if [[ "$1" == "simctl" && "$2" == "clone" ]]; then
  n="$(cat "${MOCK_DIR}/clone_count")"
  n=$((n + 1))
  printf '%s\n' "${n}" > "${MOCK_DIR}/clone_count"
  mode="$(cat "${MOCK_DIR}/mode")"
  fail=0
  if [[ "${mode}" == "fail-all" ]]; then
    fail=1
  fi
  if [[ "${mode}" == "fail-twice" && "${n}" -lt 3 ]]; then
    fail=1
  fi
  if [[ "${fail}" -eq 1 ]]; then
    printf '%s\n' "Device was allocated but was stuck in creation state." >&2
    printf '%s\n' "1" > "${MOCK_DIR}/stuck"
    printf '%s\n' "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE"
    exit 22
  fi
  rm -f "${MOCK_DIR}/stuck"
  printf '%s\n' "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
  exit 0
fi
if [[ "$1" == "simctl" && "$2" == "list" ]]; then
  if [[ -f "${MOCK_DIR}/stuck" ]]; then
    printf '%s\n' "{\"devices\":{\"ios\":[{\"udid\":\"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB\",\"name\":\"LOJO Spare iPhone\",\"state\":\"Creating\"},{\"udid\":\"DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD\",\"name\":\"iPhone\",\"state\":\"Creating\"},{\"udid\":\"${CONTROLLER_UDID}\",\"name\":\"iPhone 16\",\"state\":\"Shutdown\"}]}}"
  else
    printf '%s\n' "{\"devices\":{\"ios\":[{\"udid\":\"${CONTROLLER_UDID}\",\"name\":\"iPhone 16\",\"state\":\"Shutdown\"}]}}"
  fi
  exit 0
fi
if [[ "$1" == "simctl" && "$2" == "delete" ]]; then
  printf '%s\n' "$3" >> "${MOCK_DIR}/deleted"
  exit 0
fi
printf 'unexpected xcrun %s\n' "$*" >&2
exit 1
EOF
  chmod +x "${bin}/xcrun"
  export MOCK_DIR="${tmp}"
  export PATH="${bin}:${PATH}"
  export CONTROLLER_UDID="CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"
  sleep() {
    printf '%s\n' "$1" >> "${MOCK_DIR}/sleeps"
  }

  reset_case() {
    local mode="$1"
    printf '%s\n' "0" > "${MOCK_DIR}/clone_count"
    printf '%s\n' "${mode}" > "${MOCK_DIR}/mode"
    : > "${MOCK_DIR}/calls"
    : > "${MOCK_DIR}/sleeps"
    : > "${MOCK_DIR}/deleted"
    rm -f "${MOCK_DIR}/stuck"
    DEVICE_UDID=""
  }
  fail_test() {
    echo "self-test failed: $*" >&2
    exit 1
  }
  assert_deleted_spares_only() {
    local id
    for id in \
      EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE \
      BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB \
      DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD
    do
      if ! grep -qx "${id}" "${MOCK_DIR}/deleted"; then
        fail_test "missing delete of ${id}"
      fi
    done
    if grep -q "${CONTROLLER_UDID}" "${MOCK_DIR}/deleted"; then
      fail_test "deleted the controller"
    fi
  }

  reset_case succeed
  if ! clone_spare_iphone 2>"${tmp}/err"; then
    fail_test "first-attempt success returned failure"
  fi
  if [[ "${DEVICE_UDID}" != "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" ]]; then
    fail_test "unexpected spare udid ${DEVICE_UDID}"
  fi
  if [[ "$(cat "${MOCK_DIR}/clone_count")" != "1" ]]; then
    fail_test "success path cloned more than once"
  fi
  if [[ -s "${MOCK_DIR}/sleeps" || -s "${MOCK_DIR}/deleted" ]]; then
    fail_test "success path waited or deleted"
  fi
  if ! grep -q "simctl clone attempt 1/3" "${tmp}/err"; then
    fail_test "success path did not log attempt 1"
  fi
  if grep -q "simctl clone attempt 2/3" "${tmp}/err"; then
    fail_test "success path logged a second attempt"
  fi

  reset_case fail-twice
  if ! clone_spare_iphone 2>"${tmp}/err"; then
    fail_test "retry should have succeeded on attempt 3"
  fi
  if [[ "${DEVICE_UDID}" != "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA" ]]; then
    fail_test "retry left udid ${DEVICE_UDID}"
  fi
  if [[ "$(cat "${MOCK_DIR}/clone_count")" != "3" ]]; then
    fail_test "retry clone count $(cat "${MOCK_DIR}/clone_count")"
  fi
  printf '%s\n' 5 15 > "${tmp}/expect-sleep"
  if ! cmp -s "${tmp}/expect-sleep" "${MOCK_DIR}/sleeps"; then
    fail_test "retry backoff was $(paste -sd, "${MOCK_DIR}/sleeps")"
  fi
  assert_deleted_spares_only
  if ! grep -q "simctl clone attempt 1/3" "${tmp}/err" \
    || ! grep -q "simctl clone attempt 2/3" "${tmp}/err" \
    || ! grep -q "simctl clone attempt 3/3" "${tmp}/err"; then
    fail_test "retry did not log every attempt"
  fi
  if ! grep -q "Waiting 5s before simctl clone attempt 2/3" "${tmp}/err" \
    || ! grep -q "Waiting 15s before simctl clone attempt 3/3" "${tmp}/err"; then
    fail_test "retry did not log the backoff"
  fi
  if grep -q "Waiting 30s" "${tmp}/err"; then
    fail_test "30s wait was used before a fourth attempt"
  fi

  reset_case fail-all
  if clone_spare_iphone 2>"${tmp}/err"; then
    fail_test "three failures should fail the gate"
  fi
  if [[ -n "${DEVICE_UDID}" ]]; then
    fail_test "failed clone left DEVICE_UDID set"
  fi
  if [[ "$(cat "${MOCK_DIR}/clone_count")" != "3" ]]; then
    fail_test "failure path clone count $(cat "${MOCK_DIR}/clone_count")"
  fi
  if ! cmp -s "${tmp}/expect-sleep" "${MOCK_DIR}/sleeps"; then
    fail_test "failure backoff was $(paste -sd, "${MOCK_DIR}/sleeps")"
  fi
  assert_deleted_spares_only
  if ! grep -q "simctl clone failed after 3 attempts" "${tmp}/err"; then
    fail_test "failure path did not log the final failure"
  fi
  if ! grep -q "Cleaning up half-created simulators" "${tmp}/err"; then
    fail_test "failure path did not log cleanup"
  fi

  rm -rf "${tmp}"
  echo "remote-pair clone retry self-test ok"
}

if [[ "${1:-}" == "--self-test" ]]; then
  self_test_clone_retry
  exit 0
fi

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
  if [[ -n "${GATEWAY_STATE:-}" ]]; then
    rm -rf "${GATEWAY_STATE}"
  fi
}
trap cleanup EXIT

# The pair talks to the site gateway, not the standalone loopback relay.
if [[ ! -d "${ROOT}/sidecar/node_modules/express" ]]; then
  (cd "${ROOT}/sidecar" && npm ci --omit=dev)
fi
GATEWAY_STATE="$(mktemp -d)"
STATE_DIR="${GATEWAY_STATE}" \
BIND=127.0.0.1 \
PORT="${PORT}" \
PUBNODE_URL="http://127.0.0.1:9" \
LOJO_REMOTE_CODE="${CODE}" \
ONLINE_MS=12000 \
  node "${ROOT}/sidecar/server.js" >/tmp/lojo-remote-relay.log 2>&1 &
RELAY_PID=$!
for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${PORT}/health" | grep -q ranch-field-api; then
    break
  fi
  sleep 0.2
done
curl -sf "http://127.0.0.1:${PORT}/health" | grep -q ranch-field-api
code_status="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1/phones")"
if [[ "${code_status}" != "401" ]]; then
  echo "The gateway did not require the paired network code." >&2
  exit 1
fi

bash scripts/ios-prepare.sh
# Clone an already-compatible iPhone. Creating from the last device type fails
# when that type does not match the newest runtime ("Incompatible device").
CONTROLLER_UDID="$(bash scripts/ios-sim-udid.sh)"
clone_spare_iphone
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
print("relay pair check ok")
PY
