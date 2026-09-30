#!/usr/bin/env bash
# Site gateway TLS: per-site private CA, server certificate, rotation and phone pairing.
#
#   scripts/gateway-tls.sh init        create the site CA + first server cert (once per site)
#   scripts/gateway-tls.sh rotate      new server key + cert from the same CA, reload gateway
#                                      (phones keep working: they pin the CA, not the server cert)
#   scripts/gateway-tls.sh rotate-ca   new CA + server cert, reload gateway; every phone must re-pair
#   scripts/gateway-tls.sh status      fingerprints, SANs and expiry dates (never prints keys)
#   scripts/gateway-tls.sh pair        show the phone pairing QR code (and write a PNG)
#
# Private keys never enter the repo and are never printed:
#   CA key      ~/.config/lojo-gateway-tls/ca.key                 (0600, dir 0700)
#   server key  ~/.local/state/ranch-field-api/tls/server.key     (0600, dir 0700)
# Site settings (public, editable): ~/.config/lojo-gateway-tls/site.env
# Renaming a site: edit SITE_NAME there, then `rotate` (new leaf + name, same CA, no re-pair)
# and `pair` (new QR). The CA subject keeps the name it was created with; phones pin the CA
# by fingerprint and take the displayed name from the gateway, so that's harmless.
set -euo pipefail
umask 077

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CA_DIR="${LOJO_TLS_CA_DIR:-$HOME/.config/lojo-gateway-tls}"
TLS_DIR="${LOJO_TLS_DIR:-$HOME/.local/state/ranch-field-api/tls}"
NODE="${NODE:-$HOME/.nvm/versions/node/v20.20.1/bin/node}"
SERVER_DAYS=397    # stay under Apple's 398/825-day TLS server certificate limits
CA_DAYS=3650

mkdir -p "$CA_DIR" "$TLS_DIR"
chmod 700 "$CA_DIR" "$TLS_DIR"

SITE_ENV="$CA_DIR/site.env"
if [[ ! -f "$SITE_ENV" ]]; then
  cat >"$SITE_ENV" <<'EOF'
# Public site settings for scripts/gateway-tls.sh (no secrets here).
# These defaults are the santacomputa site's. For another site, edit every line before `init`.
SITE_NAME="LOJO VPN"
# Every address or name a phone may use to reach this gateway must be listed.
SANS="IP:192.168.7.103,IP:100.96.1.18,IP:127.0.0.1,DNS:santacomputa,DNS:santacomputa.local,DNS:localhost"
LAN_URL="https://192.168.7.103:8443"
OVERLAY_URL="https://100.96.1.18:8443"
EOF
  chmod 600 "$SITE_ENV"
fi
# shellcheck disable=SC1090
source "$SITE_ENV"

fp() { openssl x509 -in "$1" -outform DER | sha256sum | cut -d' ' -f1 | sed 's/../&:/g; s/:$//' | tr a-f A-F; }

make_ca() {
  openssl ecparam -name prime256v1 -genkey -noout -out "$CA_DIR/ca.key.new"
  openssl req -x509 -new -key "$CA_DIR/ca.key.new" -sha256 -days "$CA_DAYS" \
    -subj "/O=LOJO Private Networks/CN=${SITE_NAME} site CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" \
    -out "$CA_DIR/ca.crt.new" 2>/dev/null
  if [[ -f "$CA_DIR/ca.crt" ]]; then
    stamp="$(date +%Y%m%d%H%M%S)"
    mv "$CA_DIR/ca.crt" "$CA_DIR/ca.crt.retired.$stamp"
    mv "$CA_DIR/ca.key" "$CA_DIR/ca.key.retired.$stamp"
  fi
  mv "$CA_DIR/ca.key.new" "$CA_DIR/ca.key"
  mv "$CA_DIR/ca.crt.new" "$CA_DIR/ca.crt"
  chmod 600 "$CA_DIR"/ca.key* "$CA_DIR"/ca.crt*
}

make_server() {
  local work ext
  work="$(mktemp -d "$TLS_DIR/.issue.XXXXXX")"
  ext="$work/ext.cnf"
  cat >"$ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=${SANS}
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
  openssl ecparam -name prime256v1 -genkey -noout -out "$work/server.key"
  openssl req -new -key "$work/server.key" -subj "/O=LOJO Private Networks/CN=${SITE_NAME} gateway" \
    -out "$work/server.csr"
  openssl x509 -req -in "$work/server.csr" -CA "$CA_DIR/ca.crt" -CAkey "$CA_DIR/ca.key" \
    -set_serial "0x$(openssl rand -hex 16)" -days "$SERVER_DAYS" -sha256 -extfile "$ext" \
    -out "$work/server.crt" 2>/dev/null
  openssl verify -CAfile "$CA_DIR/ca.crt" "$work/server.crt" >/dev/null
  cat "$work/server.crt" "$CA_DIR/ca.crt" >"$work/fullchain.crt"
  cp "$CA_DIR/ca.crt" "$work/ca.crt"
  chmod 600 "$work"/*
  mv "$work/server.key" "$TLS_DIR/server.key"
  mv "$work/fullchain.crt" "$TLS_DIR/fullchain.crt"
  mv "$work/server.crt" "$TLS_DIR/server.crt"
  mv "$work/ca.crt" "$TLS_DIR/ca.crt"
  rm -rf "$work"
  write_site
}

# The name the gateway reports in /v1/network (public; served over pinned HTTPS).
write_site() {
  SITE_NAME="$SITE_NAME" python3 -c 'import json,os; print(json.dumps({"name": os.environ["SITE_NAME"]}))' \
    >"$TLS_DIR/site.json.new"
  chmod 600 "$TLS_DIR/site.json.new"
  mv "$TLS_DIR/site.json.new" "$TLS_DIR/site.json"
}

reload_gateway() {
  if systemctl --user is-active --quiet ranch-field-api.service; then
    systemctl --user kill -s HUP ranch-field-api.service
    sleep 1
    # Gateways older than 1.4.0 exit on SIGHUP instead of reloading.
    systemctl --user is-active --quiet ranch-field-api.service || systemctl --user start ranch-field-api.service
    echo "gateway reloaded"
  else
    echo "gateway not running; it will pick up the certificate on start"
  fi
}

status() {
  [[ -f "$TLS_DIR/server.crt" ]] || { echo "no server certificate yet; run: $0 init"; exit 1; }
  echo "Site:            ${SITE_NAME} (gateway serves: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$TLS_DIR/site.json" 2>/dev/null || echo "none; run rotate"))"
  echo "Site CA SHA-256: $(fp "$CA_DIR/ca.crt")"
  echo "CA expires:      $(openssl x509 -in "$CA_DIR/ca.crt" -noout -enddate | cut -d= -f2)"
  echo "Server SHA-256:  $(fp "$TLS_DIR/server.crt")"
  echo "Server expires:  $(openssl x509 -in "$TLS_DIR/server.crt" -noout -enddate | cut -d= -f2)"
  echo "Server names:    $(openssl x509 -in "$TLS_DIR/server.crt" -noout -ext subjectAltName | tail -n +2 | tr -d ' ')"
  if ! openssl x509 -in "$TLS_DIR/server.crt" -noout -checkend $((30 * 86400)) >/dev/null; then
    echo "WARNING: server certificate expires within 30 days; run: $0 rotate"
  fi
  echo "Key files:       $(stat -c '%a %n' "$CA_DIR/ca.key" "$TLS_DIR/server.key" | tr '\n' ' ')"
}

case "${1:-status}" in
  init)
    if [[ -f "$CA_DIR/ca.key" ]]; then
      echo "site CA already exists (use rotate or rotate-ca)"; exit 1
    fi
    make_ca
    make_server
    reload_gateway
    status
    ;;
  rotate)
    make_server
    reload_gateway
    status
    ;;
  rotate-ca)
    make_ca
    make_server
    reload_gateway
    status
    echo "Every phone must re-pair: run $0 pair and scan the new code."
    ;;
  status)
    status
    ;;
  pair)
    SITE_NAME="$SITE_NAME" LAN_URL="$LAN_URL" OVERLAY_URL="$OVERLAY_URL" \
      "$NODE" "$REPO/sidecar/pair.js" "$TLS_DIR/ca.crt" "$TLS_DIR/pairing-qr.png"
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2
    ;;
esac
