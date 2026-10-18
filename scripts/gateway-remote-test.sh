#!/usr/bin/env bash
# The site gateway, not the standalone relay, serves iPhone Remote Controller.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ ! -d "${ROOT}/sidecar/node_modules/express" ]]; then
  (cd "${ROOT}/sidecar" && npm ci --omit=dev)
fi

STATE="$(mktemp -d)"
PORT=18793
PID=""
cleanup() {
  if [[ -n "${PID}" ]]; then
    kill "${PID}" >/dev/null 2>&1 || true
  fi
  rm -rf "${STATE}"
}
trap cleanup EXIT

STATE_DIR="${STATE}" \
BIND=127.0.0.1 \
PORT="${PORT}" \
PUBNODE_URL="http://127.0.0.1:9" \
LOJO_REMOTE_CODE="ci-remote" \
ONLINE_MS=12000 \
  node "${ROOT}/sidecar/server.js" >"${STATE}/gateway.log" 2>&1 &
PID=$!

for _ in $(seq 1 50); do
  if curl -sf "http://127.0.0.1:${PORT}/health" | grep -q ranch-field-api; then
    break
  fi
  sleep 0.2
done
curl -sf "http://127.0.0.1:${PORT}/v1/network" | grep -q '"version":"1.5.0"'
code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/v1/phones")"
test "${code}" = "401"
curl -sf -H "X-Lojo-Network: ci-remote" -H "Content-Type: application/json" \
  -d '{"id":"phone-1","name":"Spare iPhone","batteryPercent":81,"charging":false,"schedules":[]}' \
  "http://127.0.0.1:${PORT}/v1/phones" | grep -q '"online":true'
curl -sf -H "X-Lojo-Network: ci-remote" "http://127.0.0.1:${PORT}/v1/phones" | grep -q 'Spare iPhone'
echo "gateway remote controller ok"
