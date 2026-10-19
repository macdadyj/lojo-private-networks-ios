#!/usr/bin/env bash
# Archive with manual distribution signing and upload to TestFlight.
# Imports the shared iOS Distribution certificate from DIST_CERT_P12 into a
# temporary keychain, then fetches or creates App Store profiles tied to
# certificate VJ5MXTN7UT. Does not create or delete distribution certificates.
# Does not print secret values. The workflow deletes the keychain in an always() step.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP="${ROOT}/App"

# First TestFlight upload for this app. The build number is the GitHub run
# number plus this offset. A re-run of the same run appends .attempt so App
# Store Connect does not reject a repeated upload.
BUILD_NUMBER_OFFSET=0
compute_build_number() {
  local run_number="$1" attempt="${2:-1}" number
  if [[ ! "${run_number}" =~ ^[0-9]+$ ]]; then
    run_number=1
  fi
  number=$((run_number + BUILD_NUMBER_OFFSET))
  if [[ "${attempt}" != "1" ]]; then
    number="${number}.${attempt}"
  fi
  printf '%s' "${number}"
}

# Writes AuthKey_<id>.p8 from ASC_KEY_P8. Accepts base64 (whitespace ignored)
# or PEM text that begins with -----BEGIN PRIVATE KEY-----. Error text never
# includes the secret.
write_api_key() {
  python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path

raw = os.environ.get("ASC_KEY_P8", "")
text = raw.replace("\r\n", "\n").replace("\r", "\n").lstrip("\ufeff").strip()
destination = Path(os.environ["KEY_PATH"])
if text.startswith("-----BEGIN PRIVATE KEY-----"):
    if "PRIVATE KEY" not in text:
        sys.exit("ASC_KEY_P8 does not look like a private key.")
    if not text.endswith("\n"):
        text += "\n"
    destination.write_text(text)
    sys.exit(0)
compact = "".join(text.split())
if not compact:
    sys.exit("ASC_KEY_P8 is empty.")
pad = (-len(compact)) % 4
try:
    data = base64.b64decode(compact + ("=" * pad), validate=True)
except Exception:
    sys.exit("ASC_KEY_P8 is not valid base64 and is not a PEM private key.")
if b"PRIVATE KEY" not in data:
    sys.exit("ASC_KEY_P8 decoded, but it does not look like a .p8 private key.")
destination.write_bytes(data)
PY
}

signing_dir() {
  local root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  printf '%s/lojo-dist-signing' "${root%/}"
}

signing_keychain() {
  printf '%s/signing.keychain-db' "$(signing_dir)"
}

# Writes a PKCS#12 file from DIST_CERT_P12 (base64, whitespace ignored).
# Error text never includes the secret.
decode_p12() {
  python3 - <<'PY'
import base64
import os
import sys
from pathlib import Path

raw = os.environ.get("DIST_CERT_P12", "")
compact = "".join(raw.split())
destination = Path(os.environ["P12_PATH"])
if not compact:
    sys.exit("DIST_CERT_P12 is empty.")
pad = (-len(compact)) % 4
try:
    data = base64.b64decode(compact + ("=" * pad), validate=True)
except Exception:
    sys.exit("DIST_CERT_P12 is not valid base64.")
if not data or data[0] != 0x30:
    sys.exit("DIST_CERT_P12 did not decode to a PKCS#12 file.")
destination.write_bytes(data)
PY
}

add_keychain_to_search_list() {
  python3 - "$1" <<'PY'
import subprocess
import sys

keychain = sys.argv[1]
listed = subprocess.run(
    ["security", "list-keychains", "-d", "user"],
    capture_output=True,
    text=True,
    check=False,
)
paths = [keychain]
for line in listed.stdout.splitlines():
    item = line.strip().strip('"')
    if item and item != keychain:
        paths.append(item)
subprocess.run(
    ["security", "list-keychains", "-d", "user", "-s", *paths],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=True,
)
PY
}

import_dist_keychain() {
  local dir keychain passfile p12
  if [[ -z "${DIST_CERT_P12:-}" || -z "${DIST_CERT_PASSWORD:-}" ]]; then
    echo "Missing GitHub secret DIST_CERT_P12 or DIST_CERT_PASSWORD." >&2
    exit 1
  fi
  dir="$(signing_dir)"
  rm -rf "${dir}"
  mkdir -p "${dir}"
  chmod 700 "${dir}"
  keychain="$(signing_keychain)"
  passfile="${dir}/keychain.pass"
  p12="${dir}/distribution.p12"
  P12_PATH="${p12}" decode_p12
  chmod 600 "${p12}"
  openssl rand -base64 32 | tr -d '\n' > "${passfile}"
  chmod 600 "${passfile}"
  python3 - "$keychain" "$passfile" "$p12" <<'PY'
import os
import pathlib
import subprocess
import sys

keychain, passfile, p12 = sys.argv[1:]
keychain_password = pathlib.Path(passfile).read_text()
certificate_password = os.environ["DIST_CERT_PASSWORD"]
steps = (
    ["security", "create-keychain", "-p", keychain_password, keychain],
    ["security", "set-keychain-settings", "-lut", "21600", keychain],
    ["security", "unlock-keychain", "-p", keychain_password, keychain],
    [
        "security", "import", p12,
        "-k", keychain,
        "-P", certificate_password,
        "-f", "pkcs12",
        "-A",
        "-T", "/usr/bin/codesign",
        "-T", "/usr/bin/security",
    ],
    [
        "security", "set-key-partition-list",
        "-S", "apple-tool:,apple:,codesign:",
        "-s",
        "-k", keychain_password,
        keychain,
    ],
)
for command in steps:
    result = subprocess.run(command, capture_output=True)
    if result.returncode != 0:
        sys.stderr.write("Could not import the shared distribution certificate into the temporary keychain.\n")
        sys.exit(result.returncode or 1)
PY
  add_keychain_to_search_list "${keychain}"
  security default-keychain -s "${keychain}" >/dev/null
  rm -f "${p12}"
  if ! security find-identity -p codesigning "${keychain}" 2>/dev/null | grep -q "Distribution"; then
    echo "The shared distribution certificate did not import into the temporary keychain." >&2
    exit 1
  fi
  echo "Imported the shared distribution certificate into a temporary keychain."
}

unlock_dist_keychain() {
  local dir keychain passfile
  dir="$(signing_dir)"
  keychain="$(signing_keychain)"
  passfile="${dir}/keychain.pass"
  if [[ ! -e "${keychain}" || ! -f "${passfile}" ]]; then
    echo "The shared distribution certificate is not in a temporary keychain." >&2
    echo "Run archive-upload.sh --import-keychain before archiving." >&2
    exit 1
  fi
  python3 - "$keychain" "$passfile" <<'PY'
import pathlib
import subprocess
import sys

keychain, passfile = sys.argv[1:]
password = pathlib.Path(passfile).read_text()
result = subprocess.run(
    ["security", "unlock-keychain", "-p", password, keychain],
    capture_output=True,
)
if result.returncode != 0:
    sys.stderr.write("Could not unlock the temporary signing keychain.\n")
    sys.exit(result.returncode or 1)
PY
  add_keychain_to_search_list "${keychain}"
  security default-keychain -s "${keychain}" >/dev/null
}

delete_dist_keychain() {
  local dir keychain
  dir="$(signing_dir)"
  keychain="$(signing_keychain)"
  if command -v security >/dev/null 2>&1; then
    security delete-keychain "${keychain}" >/dev/null 2>&1 || true
    security default-keychain -s login.keychain-db >/dev/null 2>&1 || true
    python3 - "$keychain" <<'PY' || true
import subprocess
import sys

keychain = sys.argv[1]
listed = subprocess.run(
    ["security", "list-keychains", "-d", "user"],
    capture_output=True,
    text=True,
    check=False,
)
paths = []
for line in listed.stdout.splitlines():
    item = line.strip().strip('"')
    if item and item != keychain:
        paths.append(item)
if not paths:
    paths = ["login.keychain-db"]
subprocess.run(
    ["security", "list-keychains", "-d", "user", "-s", *paths],
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    check=False,
)
PY
  fi
  rm -rf "${dir}"
  echo "Deleted the temporary signing keychain."
}

check_encryption() {
  local plist="${APP}/Info.plist"
  if ! awk '
    $0 ~ /<key>ITSAppUsesNonExemptEncryption<\/key>/ { found=1; next }
    found { exit ($0 ~ /<false\/>/) ? 0 : 1 }
    END { if (!found) exit 1 }
  ' "${plist}"; then
    echo "${plist} must set ITSAppUsesNonExemptEncryption to false." >&2
    exit 1
  fi
}

if [[ "${1:-}" == "--self-test" ]]; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "${tmp}"' EXIT
  pem=$'-----BEGIN PRIVATE KEY-----\nMIIB\n-----END PRIVATE KEY-----\n'
  b64="$(printf '%s' "${pem}" | base64 | fold -w 20)"
  run_case() {
    local label="$1"
    local value="$2"
    local out="${tmp}/${label}.p8"
    ASC_KEY_P8="${value}" KEY_PATH="${out}" write_api_key
    python3 - "${out}" "${label}" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_bytes()
if b"PRIVATE KEY" not in body or b"BEGIN" not in body:
    sys.exit("self-test failed for " + sys.argv[2])
print("asc key decode ok: " + sys.argv[2])
PY
  }
  run_case "pem" "${pem}"
  run_case "base64-wrapped" "${b64}"$'\n'
  run_case "base64-spaces" "$(printf '%s' "${pem}" | base64 | tr -d '\n' | sed 's/..../& /g')"
  if ASC_KEY_P8="not a key" KEY_PATH="${tmp}/bad.p8" write_api_key 2>"${tmp}/err"; then
    echo "self-test failed: invalid input was accepted" >&2
    exit 1
  fi
  if grep -q "not a key" "${tmp}/err"; then
    echo "self-test failed: error text included the secret" >&2
    exit 1
  fi
  echo "asc key decode rejected invalid input"
  payload=$'\x30\x82\x01\x02pkcs12-fixture'
  b64="$(printf '%s' "${payload}" | base64 | fold -w 16)"
  P12_PATH="${tmp}/fixture.p12" DIST_CERT_P12="${b64}" decode_p12
  python3 - "${tmp}/fixture.p12" <<'PY'
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_bytes()
if not body.startswith(b"\x30\x82"):
    sys.exit("self-test failed: p12 decode")
print("dist cert decode ok")
PY
  if P12_PATH="${tmp}/bad.p12" DIST_CERT_P12="not a certificate" decode_p12 2>"${tmp}/p12err"; then
    echo "self-test failed: invalid p12 was accepted" >&2
    exit 1
  fi
  if grep -q "not a certificate" "${tmp}/p12err"; then
    echo "self-test failed: p12 error text included the secret" >&2
    exit 1
  fi
  echo "dist cert decode rejected invalid input"
  rm -rf "${tmp}"
  trap - EXIT
  check_encryption
  [[ "$(compute_build_number 1 1)" == "1" ]] || { echo "self-test failed: build number for run 1" >&2; exit 1; }
  [[ "$(compute_build_number 27 1)" == "27" ]] || { echo "self-test failed: build number for run 27" >&2; exit 1; }
  [[ "$(compute_build_number 5 3)" == "5.3" ]] || { echo "self-test failed: build number for a re-run" >&2; exit 1; }
  [[ "$(compute_build_number "" 1)" == "1" ]] || { echo "self-test failed: build number without a run" >&2; exit 1; }
  echo "build number ok: run 1 -> 1, run 5 attempt 3 -> 5.3"
  python3 - "$0" <<'PY'
import sys
from pathlib import Path
text = Path(sys.argv[1]).read_text()
needles = (
    "openssl gen" + "rsa",
    "BEGIN CERTIFICATE " + "REQUEST",
    "allowProvisioning" + "Updates",
    "fast" + "lane",
)
for needle in needles:
    if needle in text:
        sys.exit("self-test failed: certificate creation is still present")
print("archive script does not mint certificates")
PY
  python3 "${SCRIPT_DIR}/asc_signing.py" --self-test
  python3 "${SCRIPT_DIR}/asc_testflight.py" --self-test
  exit 0
fi

if [[ "${1:-}" == "--import-keychain" ]]; then
  import_dist_keychain
  exit 0
fi

if [[ "${1:-}" == "--delete-keychain" ]]; then
  delete_dist_keychain
  exit 0
fi

missing=0
for name in ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_P8; do
  if [[ -z "${!name:-}" ]]; then
    echo "Missing GitHub secret ${name}." >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "Add the App Store Connect API key secrets before uploading. See README TestFlight." >&2
  exit 1
fi

if [[ -z "${DEVELOPMENT_TEAM:-}" ]]; then
  echo "Missing GitHub secret DEVELOPMENT_TEAM." >&2
  exit 1
fi
TEAM="${DEVELOPMENT_TEAM}"
BUILD_NUMBER="$(compute_build_number "${GITHUB_RUN_NUMBER:-1}" "${GITHUB_RUN_ATTEMPT:-1}")"
echo "Archive build number ${BUILD_NUMBER} for com.lojo.PrivateNetworks."
WORKDIR="$(mktemp -d)"
KEYCHAIN="$(signing_keychain)"
KEY_PATH="${WORKDIR}/private_keys/AuthKey_${ASC_KEY_ID}.p8"
cleanup() {
  local status=$?
  rm -rf "${WORKDIR}"
  exit "${status}"
}
trap cleanup EXIT
mkdir -p "${WORKDIR}/private_keys"
export KEY_PATH
umask 077
write_api_key

# Build 38 uploaded with that version and was accepted for processing.
# The old lookup hid any build that did not yet have a beta detail.
set +e
python3 "${SCRIPT_DIR}/asc_testflight.py" adopt --build "${BUILD_NUMBER}" --wait-seconds 2400
adopt=$?
set -e
if [[ "${adopt}" -eq 0 ]]; then
  echo "An already uploaded build is in the internal TestFlight group."
  exit 0
fi
if [[ "${adopt}" -ne 2 ]]; then
  exit "${adopt}"
fi

cd "${ROOT}"
if [[ ! -d "${APP}/LojoNetworks.xcodeproj" ]]; then
  bash "${SCRIPT_DIR}/ios-prepare.sh"
fi
check_encryption
unlock_dist_keychain

python3 "${SCRIPT_DIR}/asc_signing.py" prepare \
  --profiles-dir "${HOME}/Library/MobileDevice/Provisioning Profiles" \
  --team "${TEAM}" \
  --keychain "${KEYCHAIN}" \
  --pbxproj "${APP}/LojoNetworks.xcodeproj/project.pbxproj" \
  --export-plist "${ROOT}/build/ExportOptions.plist"

# Manual signing uses the installed profile and the shared certificate.
# Xcode is not given permission to create signing assets.
echo "Archiving with manual distribution signing."
xcodebuild archive \
  -project "${APP}/LojoNetworks.xcodeproj" \
  -scheme LojoNetworks \
  -destination "generic/platform=iOS" \
  -archivePath "${ROOT}/build/LojoNetworks.xcarchive" \
  -clonedSourcePackagesDirPath "${ROOT}/build/SourcePackages" \
  -derivedDataPath "${ROOT}/build/ArchiveDerivedData" \
  DEVELOPMENT_TEAM="${TEAM}" \
  CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
  MARKETING_VERSION="1.2" \
  SWIFT_ENABLE_EXPLICIT_MODULES=NO

# App Store Connect only lists 13 and 16. Later uploads never became builds.
# Stamp the archive so this upload cannot reuse an old CFBundleVersion.
python3 - "${ROOT}/build/LojoNetworks.xcarchive" "${BUILD_NUMBER}" "1.2" <<'PY'
import plistlib
import sys
from pathlib import Path

archive = Path(sys.argv[1])
build, marketing = sys.argv[2], sys.argv[3]
app_plist = archive / "Products/Applications/LojoNetworks.app/Info.plist"
meta_plist = archive / "Info.plist"
if not app_plist.is_file():
    sys.exit("The archive has no app Info.plist to stamp.")
app = plistlib.loads(app_plist.read_bytes())
print(f"Archive CFBundleVersion before stamp: {app.get('CFBundleVersion')}")
app["CFBundleVersion"] = build
app["CFBundleShortVersionString"] = marketing
app_plist.write_bytes(plistlib.dumps(app))
if meta_plist.is_file():
    meta = plistlib.loads(meta_plist.read_bytes())
    props = meta.get("ApplicationProperties") or {}
    props["CFBundleVersion"] = build
    props["CFBundleShortVersionString"] = marketing
    meta["ApplicationProperties"] = props
    meta_plist.write_bytes(plistlib.dumps(meta))
checked = plistlib.loads(app_plist.read_bytes()).get("CFBundleVersion")
if checked != build:
    sys.exit(f"The archive build number stayed {checked}.")
print(f"Stamped CFBundleVersion {build}")
PY

xcodebuild -exportArchive \
  -archivePath "${ROOT}/build/LojoNetworks.xcarchive" \
  -exportPath "${ROOT}/build/export" \
  -exportOptionsPlist "${ROOT}/build/ExportOptions.plist" \
  -authenticationKeyPath "${KEY_PATH}" \
  -authenticationKeyID "${ASC_KEY_ID}" \
  -authenticationKeyIssuerID "${ASC_ISSUER_ID}"
echo "Uploaded to App Store Connect."
echo "Releasing build ${BUILD_NUMBER} to the internal TestFlight group."
set +e
KEY_PATH="${KEY_PATH}" BUILD_NUMBER="${BUILD_NUMBER}" \
  python3 "${SCRIPT_DIR}/asc_testflight.py" release --wait-seconds 2700
release_status=$?
set -e
if [[ "${release_status}" -ne 0 ]]; then
  exit "${release_status}"
fi
echo "TestFlight build ${BUILD_NUMBER}"
