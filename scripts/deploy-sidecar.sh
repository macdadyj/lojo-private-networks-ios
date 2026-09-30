#!/usr/bin/env bash
# Install sidecar/ into the running site gateway on santacomputa and restart it.
# Talks only to the Cloud Run hub via the overlay proxy (PUBNODE_URL in the unit). Never Flex.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${SIDECAR_DIR:-$HOME/.local/share/ranch-field-api}"
NODE="${NODE:-$HOME/.nvm/versions/node/v20.20.1/bin/node}"

"$NODE" --check "$REPO/sidecar/server.js"
mkdir -p "$DEST"
if [[ -f "$DEST/server.js" ]] && ! cmp -s "$DEST/server.js" "$REPO/sidecar/server.js"; then
  cp "$DEST/server.js" "$DEST/server.js.bak.$(date +%Y%m%d%H%M%S)"
fi
cp "$REPO/sidecar/server.js" "$REPO/sidecar/package.json" "$DEST/"
if [[ ! -d "$DEST/node_modules/express" ]]; then
  (cd "$DEST" && PATH="$(dirname "$NODE"):$PATH" npm ci --omit=dev)
fi

systemctl --user restart ranch-field-api.service
sleep 3
systemctl --user is-active ranch-field-api.service
curl -fsS -m 5 http://127.0.0.1:8801/health; echo
curl -fsS -m 5 http://127.0.0.1:8801/v1/network; echo
