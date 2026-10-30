#!/usr/bin/env bash
# Run the iOS unit tests. TestFlight waits for this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${ROOT}"
WORK="$(bash scripts/pinned-relay-https-fixture.sh)"
PORT=18443
HASH="$(tr -d '[:space:]' < "${WORK}/ca.sha256")"
SERVER_PID=""
cleanup() {
  if [[ -n "${SERVER_PID}" ]]; then
    kill "${SERVER_PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${WORK}"
}
trap cleanup EXIT
python3 "${ROOT}/scripts/pinned-relay-https-server.py" "${PORT}" "${WORK}/fullchain.pem" "${WORK}/server.key" "${HASH}" \
  >"${WORK}/server.log" 2>&1 &
SERVER_PID=$!
python3 - "${WORK}/ca.crt" "${PORT}" "${HASH}" <<'PY'
import socket, ssl, sys, time
ca, port, code = sys.argv[1], int(sys.argv[2]), sys.argv[3]
ctx = ssl.create_default_context(cafile=ca)
last = None
for _ in range(50):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=2) as sock:
            with ctx.wrap_socket(sock, server_hostname="127.0.0.1") as tls:
                tls.sendall(
                    f"GET /v1/phones HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Lojo-Network: {code}\r\nConnection: close\r\n\r\n".encode()
                )
                data = b""
                while True:
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    data += chunk
        if b'"phones"' not in data:
            raise SystemExit(data.decode("utf-8", "replace"))
        sys.exit(0)
    except Exception as exc:
        last = exc
        time.sleep(0.1)
raise SystemExit(f"pinned HTTPS fixture did not answer: {last}")
PY
CHAIN="$(echo | openssl s_client -connect "127.0.0.1:${PORT}" -showcerts 2>/dev/null | grep -c "BEGIN CERTIFICATE" || true)"
test "${CHAIN}" -ge 2
bash scripts/ios-prepare.sh
UDID="$(bash scripts/ios-sim-udid.sh)"
echo "Simulator ${UDID}"
run_tests() {
  xcodebuild test \
    -project App/LojoNetworks.xcodeproj \
    -scheme LojoNetworks \
    -destination "platform=iOS Simulator,id=${UDID}" \
    -clonedSourcePackagesDirPath build/SourcePackages \
    -derivedDataPath build/DerivedData \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="-" \
    DEVELOPMENT_TEAM="" \
    ONLY_ACTIVE_ARCH=YES \
    ARCHS=arm64 \
    SWIFT_ENABLE_EXPLICIT_MODULES=NO
}
set +e
run_tests
status=$?
set -e
if [[ "${status}" -ne 0 ]]; then
  echo "iOS unit tests failed (status ${status}). Rebooting the simulator and trying once more." >&2
  xcrun simctl shutdown "${UDID}" || true
  sleep 2
  xcrun simctl boot "${UDID}" || true
  xcrun simctl bootstatus "${UDID}" -b || true
  run_tests
fi
