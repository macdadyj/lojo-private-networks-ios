#!/usr/bin/env bash
# Build a site CA and a leaf the way gateway-tls.sh does, for 127.0.0.1.
# Prints the work directory. Copies the public CA certs into the unit-test bundle.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
DEST="${ROOT}/App/Tests/PinnedRelayHTTPS/PinnedHTTPSFixture"
mkdir -p "${DEST}" "${WORK}/demoCA"
: > "${WORK}/demoCA/index.txt"
printf '01\n' > "${WORK}/demoCA/serial"

cat > "${WORK}/ca.cnf" <<'EOF'
[ca]
default_ca=CA_default
[CA_default]
dir=.
database=demoCA/index.txt
serial=demoCA/serial
new_certs_dir=demoCA
certificate=ca.crt
private_key=ca.key
default_md=sha256
policy=policy_any
x509_extensions=v3_leaf
unique_subject=no
[policy_any]
commonName=supplied
organizationName=optional
[req]
distinguished_name=dn
x509_extensions=v3_ca
prompt=no
[dn]
O=LOJO Private Networks
CN=LOJO VPN site CA
[v3_ca]
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
[v3_leaf]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=IP:192.168.7.103,IP:100.96.1.18,IP:127.0.0.1,DNS:santacomputa,DNS:santacomputa.local,DNS:localhost
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF

cd "${WORK}"
openssl ecparam -name prime256v1 -genkey -noout -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 3650 -config ca.cnf -extensions v3_ca -out ca.crt
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
openssl req -new -key leaf.key -subj "/O=LOJO Private Networks/CN=LOJO VPN gateway" -out leaf.csr
openssl ca -config ca.cnf -in leaf.csr -out leaf.crt -batch -notext -startdate 260101000000Z -enddate 271231000000Z
openssl ecparam -name prime256v1 -genkey -noout -out other.key
openssl req -x509 -new -key other.key -sha256 -days 3650 -config ca.cnf -extensions v3_ca \
  -subj "/O=LOJO Private Networks/CN=Other CA" -out other-ca.crt
openssl verify -CAfile ca.crt leaf.crt >/dev/null
cat leaf.crt ca.crt > fullchain.pem
cp leaf.key server.key
openssl x509 -in ca.crt -outform DER -out ca.der
openssl x509 -in other-ca.crt -outform DER -out other-ca.der
openssl dgst -sha256 ca.der | awk '{print tolower($NF)}' > ca.sha256
cp ca.der other-ca.der "${DEST}/"
chmod 700 "${WORK}"
printf '%s\n' "${WORK}"
