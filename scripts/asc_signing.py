#!/usr/bin/env python3
"""Install App Store profiles for the shared iOS Distribution certificate.

Uses the App Store Connect REST API (ES256 JWT, audience appstoreconnect-v1).
Does not print private keys, API tokens, certificate bytes, or passwords.
Does not create or delete distribution certificates. Profiles are fetched or
created for com.lojo.PrivateNetworks and any app extensions, and each profile
is tied to certificate VJ5MXTN7UT.
"""

import base64
import hashlib
import io
import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

API_ROOT = "https://api.appstoreconnect.apple.com"
PROFILE_TYPE = "IOS_APP_STORE"
DISTRIBUTION_CERTIFICATE_ID = "VJ5MXTN7UT"
APP_BUNDLE_ID = "com.lojo.PrivateNetworks"
TARGETS = (
    (APP_BUNDLE_ID, "LOJO Networks App Store"),
)
BUNDLE_NAMES = {
    APP_BUNDLE_ID: "LOJO Networks",
}
SIGNING_KEYS = (
    "CODE_SIGN_STYLE",
    "CODE_SIGN_IDENTITY",
    "CODE_SIGNING_ALLOWED",
    "DEVELOPMENT_TEAM",
    "PROVISIONING_PROFILE_SPECIFIER",
    "OTHER_CODE_SIGN_FLAGS",
)
DISTRIBUTION_PRODUCT_TYPES = {
    "com.apple.product-type.application",
    "com.apple.product-type.app-extension",
    "com.apple.product-type.app-extension.intents-service",
    "com.apple.product-type.app-extension.messages",
    "com.apple.product-type.extensionkit-extension",
}


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def b64url_decode(text):
    pad = "=" * ((-len(text)) % 4)
    return base64.urlsafe_b64decode(text + pad)


def der_to_raw(der):
    """Turn an OpenSSL ECDSA DER signature into the 64-byte JWT form."""
    if len(der) < 8 or der[0] != 0x30:
        raise ValueError("not a DER signature")
    index = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    numbers = []
    for _ in range(2):
        if index >= len(der) or der[index] != 0x02:
            raise ValueError("expected an integer in the signature")
        index += 1
        length = der[index]
        index += 1
        if length & 0x80:
            count = length & 0x7F
            length = int.from_bytes(der[index:index + count], "big")
            index += count
        value = der[index:index + length]
        index += length
        value = value.lstrip(b"\x00")
        if len(value) > 32:
            raise ValueError("signature integer is too wide")
        numbers.append(value.rjust(32, b"\x00"))
    return numbers[0] + numbers[1]


def raw_to_der(raw):
    if len(raw) != 64:
        raise ValueError("expected a 64-byte signature")

    def encode(part):
        value = part.lstrip(b"\x00") or b"\x00"
        if value[0] & 0x80:
            value = b"\x00" + value
        return b"\x02" + bytes([len(value)]) + value

    body = encode(raw[:32]) + encode(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def sign_es256(pem, message):
    with tempfile.NamedTemporaryFile() as key_file:
        key_file.write(pem if pem.endswith(b"\n") else pem + b"\n")
        key_file.flush()
        signed = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_file.name],
            input=message,
            capture_output=True,
            check=False,
        )
    if signed.returncode != 0 or not signed.stdout:
        raise SystemExit("Could not sign the App Store Connect request.")
    return der_to_raw(signed.stdout)


def make_jwt(pem, key_id, issuer, now):
    header = b64url(json.dumps(
        {"alg": "ES256", "kid": key_id, "typ": "JWT"},
        separators=(",", ":"),
    ).encode())
    payload = b64url(json.dumps(
        {
            "iss": issuer,
            "iat": now,
            "exp": now + (19 * 60),
            "aud": "appstoreconnect-v1",
        },
        separators=(",", ":"),
    ).encode())
    signing_input = f"{header}.{payload}".encode()
    signature = b64url(sign_es256(pem, signing_input))
    return f"{header}.{payload}.{signature}"


def certificate_limit(body):
    lowered = body.lower()
    phrases = (
        "maximum number",
        "already have",
        "too many",
        "certificate limit",
        "exceeded the maximum",
        "reached the maximum",
    )
    return any(phrase in lowered for phrase in phrases)


def stop_api(status, body, context):
    text = body.strip() or f"HTTP {status}"
    sys.stderr.write(text)
    if not text.endswith("\n"):
        sys.stderr.write("\n")
    forbidden = status == 403 or "FORBIDDEN" in body
    if forbidden and context == "certificate":
        sys.stderr.write(
            "Certificate creation was forbidden. Stopped without retrying. "
            "Nothing was revoked. An Admin App Store Connect API key may be required.\n"
        )
    elif forbidden:
        sys.stderr.write(
            f"{context} was forbidden. Stopped without retrying. Nothing was revoked.\n"
        )
    elif context == "certificate" and certificate_limit(body):
        sys.stderr.write(
            "The account is at the iOS Distribution certificate limit. "
            "Stopped. Nothing was revoked.\n"
        )
    else:
        sys.stderr.write(
            f"{context} failed with HTTP {status}. Stopped. Nothing was revoked.\n"
        )
    raise SystemExit(1)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def api(token, method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(API_ROOT + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("Accept", "application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=60) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except urllib.error.URLError:
        raise SystemExit("Could not reach App Store Connect. Stopped. Nothing was revoked.")


def load_pem(path):
    return Path(path).read_bytes()


def jwt_from_env():
    pem = load_pem(os.environ["KEY_PATH"])
    return make_jwt(
        pem,
        os.environ["ASC_KEY_ID"],
        os.environ["ASC_ISSUER_ID"],
        int(time.time()),
    )


def parse_data(status, body, context):
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        stop_api(status, body, context)
    if status not in (200, 201) or "data" not in parsed:
        stop_api(status, body, context)
    return parsed


def lookup_bundle_id(token, identifier):
    query = urllib.parse.urlencode(
        {"filter[identifier]": identifier, "limit": "5"}
    )
    status, body = api(token, "GET", "/v1/bundleIds?" + query)
    parsed = parse_data(status, body, "bundle ID lookup")
    for item in parsed["data"]:
        if item.get("attributes", {}).get("identifier") == identifier:
            return item["id"]
    return None


def ensure_bundle_id(token, identifier, name):
    found = lookup_bundle_id(token, identifier)
    if found:
        return found
    status, body = api(
        token,
        "POST",
        "/v1/bundleIds",
        {
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": identifier,
                    "name": name,
                    "platform": "IOS",
                },
            }
        },
    )
    if status == 409:
        found = lookup_bundle_id(token, identifier)
        if found:
            return found
    parsed = parse_data(status, body, "bundle ID create")
    print(f"Registered App ID {identifier}.", flush=True)
    return parsed["data"]["id"]


def delete_profile(token, profile_id):
    status, body = api(token, "DELETE", "/v1/profiles/" + urllib.parse.quote(profile_id))
    if status in (204, 404):
        return
    stop_api(status, body, "profile delete")


def preferred_profile_name(bundle_id):
    if bundle_id == APP_BUNDLE_ID:
        return "LOJO Networks App Store"
    leaf = bundle_id.rsplit(".", 1)[-1]
    return f"LOJO {leaf} App Store"[:50]


def bundle_display_name(bundle_id):
    if bundle_id in BUNDLE_NAMES:
        return BUNDLE_NAMES[bundle_id]
    return f"LOJO {bundle_id.rsplit('.', 1)[-1]}"


def fetch_distribution_certificate(token):
    """Read the shared certificate. Never creates one."""
    cert_id = DISTRIBUTION_CERTIFICATE_ID
    status, body = api(token, "GET", "/v1/certificates/" + urllib.parse.quote(cert_id))
    parsed = parse_data(status, body, "certificate")
    attributes = parsed["data"].get("attributes") or {}
    kind = attributes.get("certificateType") or "unknown"
    if kind != "IOS_DISTRIBUTION":
        raise SystemExit(
            f"App Store Connect certificate {cert_id} is {kind}, not an iOS Distribution certificate. "
            "No certificate was created."
        )
    content = attributes.get("certificateContent")
    if not content:
        raise SystemExit(
            "The shared distribution certificate had no content. No certificate was created."
        )
    try:
        der = base64.b64decode(content)
    except Exception:
        raise SystemExit(
            "The shared distribution certificate could not be read. No certificate was created."
        )
    return cert_id, der


def identity_text_matches(text, der):
    digest = hashlib.sha1(der).hexdigest().upper()
    compact = text.upper().replace(" ", "")
    return digest in compact


def assert_keychain_has_certificate(keychain, der):
    identity = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        capture_output=True,
        text=True,
        check=False,
    )
    if identity.returncode != 0 or not identity_text_matches(identity.stdout, der):
        raise SystemExit(
            "The imported distribution certificate does not match "
            f"App Store Connect certificate {DISTRIBUTION_CERTIFICATE_ID}."
        )
    exported = subprocess.run(
        ["security", "find-certificate", "-a", "-p", keychain],
        capture_output=True,
        check=False,
    )
    if exported.returncode != 0 or b"BEGIN CERTIFICATE" not in exported.stdout:
        raise SystemExit("The temporary keychain has no certificate to compare.")
    for chunk in exported.stdout.split(b"-----END CERTIFICATE-----"):
        start = chunk.find(b"-----BEGIN CERTIFICATE-----")
        if start < 0:
            continue
        pem = chunk[start:] + b"-----END CERTIFICATE-----\n"
        converted = subprocess.run(
            ["openssl", "x509", "-inform", "PEM", "-outform", "DER"],
            input=pem,
            capture_output=True,
            check=False,
        )
        if converted.returncode == 0 and converted.stdout == der:
            return
    raise SystemExit(
        "The imported distribution certificate does not match "
        f"App Store Connect certificate {DISTRIBUTION_CERTIFICATE_ID}."
    )


def signing_identity_setting(keychain):
    identity = subprocess.run(
        ["security", "find-identity", "-v", "-p", "codesigning", keychain],
        capture_output=True,
        text=True,
        check=False,
    )
    if identity.returncode != 0:
        raise SystemExit("Could not read the temporary keychain identities.")
    for line in identity.stdout.splitlines():
        if "Distribution" not in line or '"' not in line:
            continue
        name = line.split('"', 2)[1]
        if name.startswith("Apple Distribution"):
            return "Apple Distribution"
        if "Distribution" in name:
            return "iPhone Distribution"
    raise SystemExit(
        "The temporary keychain has no distribution identity for code signing."
    )


def list_app_store_profiles(token):
    profiles = []
    included = {}
    query = urllib.parse.urlencode({
        "filter[profileType]": PROFILE_TYPE,
        "include": "bundleId,certificates",
        "limit": "200",
    })
    path = "/v1/profiles?" + query
    for _page in range(10):
        status, body = api(token, "GET", path)
        parsed = parse_data(status, body, "profile lookup")
        profiles.extend(parsed.get("data") or [])
        for item in parsed.get("included") or []:
            included[(item.get("type"), item.get("id"))] = item
        nxt = ((parsed.get("links") or {}).get("next")) or ""
        if nxt.startswith(API_ROOT):
            path = nxt[len(API_ROOT):]
            continue
        break
    return profiles, included


def profile_certificate_ids(profile):
    data = ((profile.get("relationships") or {}).get("certificates") or {}).get("data") or []
    return [item.get("id") for item in data if item.get("id")]


def profile_matches_bundle(profile, bundle_resource_id, bundle_identifier, included):
    rel = (((profile.get("relationships") or {}).get("bundleId") or {}).get("data") or {}).get("id")
    if rel and bundle_resource_id and rel == bundle_resource_id:
        return True
    item = included.get(("bundleIds", rel))
    identifier = ((item or {}).get("attributes") or {}).get("identifier")
    return identifier == bundle_identifier


def profile_is_current(profile, now):
    attributes = profile.get("attributes") or {}
    if attributes.get("profileState") not in (None, "ACTIVE"):
        return False
    raw = attributes.get("expirationDate")
    if not raw:
        return True
    try:
        expiry = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return True
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    return expiry > now


def choose_profile(profiles, included, bundle_resource_id, bundle_identifier, certificate_id):
    now = datetime.now(timezone.utc)
    matches = []
    for profile in profiles:
        if certificate_id not in profile_certificate_ids(profile):
            continue
        if not profile_matches_bundle(profile, bundle_resource_id, bundle_identifier, included):
            continue
        if not profile_is_current(profile, now):
            continue
        matches.append(profile)
    if not matches:
        return None
    matches.sort(key=lambda item: (item.get("attributes") or {}).get("expirationDate") or "")
    return matches[-1]


def profile_material(token, profile):
    content = (profile.get("attributes") or {}).get("profileContent")
    if not content:
        status, body = api(token, "GET", "/v1/profiles/" + urllib.parse.quote(profile["id"]))
        parsed = parse_data(status, body, "profile")
        profile = parsed["data"]
        content = (profile.get("attributes") or {}).get("profileContent")
    if not content:
        raise SystemExit("The App Store profile had no content. No certificate was created.")
    try:
        raw = base64.b64decode(content)
    except Exception:
        raise SystemExit("The App Store profile could not be read. No certificate was created.")
    name = (profile.get("attributes") or {}).get("name") or ""
    if not name:
        raise SystemExit("The App Store profile had no name. No certificate was created.")
    return profile["id"], name, raw


def delete_stale_named_profile(token, name, certificate_id):
    query = urllib.parse.urlencode({
        "filter[name]": name,
        "filter[profileType]": PROFILE_TYPE,
        "include": "certificates",
        "limit": "20",
    })
    status, body = api(token, "GET", "/v1/profiles?" + query)
    parsed = parse_data(status, body, "profile lookup")
    for item in parsed.get("data") or []:
        attributes = item.get("attributes") or {}
        if attributes.get("name") != name or attributes.get("profileType") != PROFILE_TYPE:
            continue
        if (item.get("relationships") or {}).get("certificates") is None:
            status, body = api(
                token, "GET", "/v1/profiles/" + urllib.parse.quote(item["id"]) + "?include=certificates"
            )
            parsed = parse_data(status, body, "profile lookup")
            item = parsed["data"]
        if certificate_id in profile_certificate_ids(item):
            continue
        delete_profile(token, item["id"])


def create_profile(token, name, bundle_resource_id, certificate_id):
    status, body = api(
        token,
        "POST",
        "/v1/profiles",
        {
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": name,
                    "profileType": PROFILE_TYPE,
                },
                "relationships": {
                    "bundleId": {
                        "data": {"type": "bundleIds", "id": bundle_resource_id}
                    },
                    "certificates": {
                        "data": [{"type": "certificates", "id": certificate_id}]
                    },
                },
            }
        },
    )
    if status == 409:
        return None
    parsed = parse_data(status, body, "profile")
    profile = parsed["data"]
    if certificate_id not in profile_certificate_ids(profile):
        raise SystemExit(
            "The new App Store profile is not tied to "
            f"{DISTRIBUTION_CERTIFICATE_ID}. No certificate was created."
        )
    return profile


def ensure_profile(token, bundle_id, bundle_resource_id, certificate_id, profiles, included):
    chosen = choose_profile(
        profiles, included, bundle_resource_id, bundle_id, certificate_id
    )
    if chosen is not None:
        print(f"Using the App Store profile for {bundle_id}.", flush=True)
        return profile_material(token, chosen)
    name = preferred_profile_name(bundle_id)
    print(f"Creating an App Store profile for {bundle_id}.", flush=True)
    created = create_profile(token, name, bundle_resource_id, certificate_id)
    if created is None:
        profiles, included = list_app_store_profiles(token)
        chosen = choose_profile(
            profiles, included, bundle_resource_id, bundle_id, certificate_id
        )
        if chosen is not None:
            print(f"Using the App Store profile for {bundle_id}.", flush=True)
            return profile_material(token, chosen)
        delete_stale_named_profile(token, name, certificate_id)
        created = create_profile(token, name, bundle_resource_id, certificate_id)
    if created is None:
        raise SystemExit(
            f"Could not create an App Store profile for {bundle_id}. No certificate was created."
        )
    return profile_material(token, created)


def install_profile(raw, profile_id, directory):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / f"{profile_id}.mobileprovision"
    path.write_bytes(raw)
    os.chmod(path, 0o644)
    return path


def bundle_in_block(text, bundle_id):
    return (
        f"PRODUCT_BUNDLE_IDENTIFIER = {bundle_id};" in text
        or f'PRODUCT_BUNDLE_IDENTIFIER = "{bundle_id}";' in text
    )


def patch_pbxproj(text, team, keychain, profiles, identity="Apple Distribution"):
    lines = text.splitlines(keepends=True)
    output = []
    index = 0
    while index < len(lines):
        if "buildSettings = {" not in lines[index]:
            output.append(lines[index])
            index += 1
            continue
        block = [lines[index]]
        index += 1
        depth = lines[index - 1].count("{") - lines[index - 1].count("}")
        while index < len(lines) and depth > 0:
            block.append(lines[index])
            depth += lines[index].count("{") - lines[index].count("}")
            index += 1
        joined = "".join(block)
        matched = None
        for bundle_id, profile_name in profiles:
            if bundle_in_block(joined, bundle_id):
                matched = profile_name
                break
        if matched is None:
            output.extend(block)
            continue
        output.extend(rewrite_settings(block, team, keychain, matched, identity))
    return "".join(output)


def rewrite_settings(block, team, keychain, profile_name, identity="Apple Distribution"):
    indent = "\t\t\t\t"
    for line in block:
        stripped = line.lstrip()
        if stripped.startswith("PRODUCT_BUNDLE_IDENTIFIER"):
            indent = line[:len(line) - len(stripped)]
            break
    kept = []
    for line in block[:-1]:
        stripped = line.strip()
        if any(stripped.startswith(key + " ") or stripped.startswith(key + "=") for key in SIGNING_KEYS):
            continue
        kept.append(line)
    flag = f"--keychain {keychain}"
    settings = [
        f"{indent}CODE_SIGN_STYLE = Manual;\n",
        f"{indent}CODE_SIGNING_ALLOWED = YES;\n",
        f'{indent}CODE_SIGN_IDENTITY = "{identity}";\n',
        f"{indent}DEVELOPMENT_TEAM = {team};\n",
        f'{indent}PROVISIONING_PROFILE_SPECIFIER = "{profile_name}";\n',
        f'{indent}OTHER_CODE_SIGN_FLAGS = "{flag}";\n',
    ]
    kept.extend(settings)
    kept.append(block[-1])
    return kept


def write_export_options(path, team, profiles, identity="Apple Distribution"):
    payload = {
        "method": "app-store-connect",
        "signingStyle": "manual",
        "signingCertificate": identity,
        "teamID": team,
        "destination": "upload",
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,
        "provisioningProfiles": {bundle_id: name for bundle_id, name in profiles},
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        plistlib.dump(payload, handle)


def extract_braces(text, open_index):
    depth = 0
    index = open_index
    while index < len(text):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
        elif char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                if text[index] == "\\":
                    index += 1
                index += 1
        index += 1
    return ""


def pbx_objects(text):
    objects = {}
    pattern = re.compile(r"(?m)^[ \t]*([A-Fa-f0-9]{24})(?: /\* [^*]* \*/)? = \{")
    for match in pattern.finditer(text):
        objects[match.group(1)] = extract_braces(text, match.end() - 1)
    return objects


def pbx_field(body, name):
    match = re.search(rf"(?m)^[ \t]*{re.escape(name)} = ([^;]+);", body)
    if not match:
        return None
    value = match.group(1).strip().strip('"')
    return value.split("/*", 1)[0].strip()


def distribution_bundles(text):
    """App and app-extension bundle ids. Test bundles are left unsigned by this."""
    objects = pbx_objects(text)
    found = []
    seen = set()
    for body in objects.values():
        if "isa = PBXNativeTarget;" not in body:
            continue
        product = pbx_field(body, "productType")
        if product not in DISTRIBUTION_PRODUCT_TYPES:
            continue
        list_id = pbx_field(body, "buildConfigurationList")
        list_body = objects.get(list_id or "", "")
        configs = re.search(r"buildConfigurations = \((.*?)\);", list_body, re.S)
        config_ids = re.findall(r"[A-Fa-f0-9]{24}", configs.group(1) if configs else "")
        for config_id in config_ids:
            bundle_id = pbx_field(objects.get(config_id, ""), "PRODUCT_BUNDLE_IDENTIFIER")
            if not bundle_id or bundle_id in seen:
                continue
            if bundle_id.endswith(".tests") or bundle_id.endswith(".uitests"):
                continue
            seen.add(bundle_id)
            found.append(bundle_id)
    found.sort(key=lambda item: (item != APP_BUNDLE_ID, item))
    return found


def prepare(argv):
    profiles_dir = Path(argv["profiles_dir"]).expanduser()
    project = Path(argv["pbxproj"])
    text = project.read_text()
    bundles = distribution_bundles(text)
    if APP_BUNDLE_ID not in bundles:
        raise SystemExit(
            f"Could not find {APP_BUNDLE_ID} in the Xcode project. No certificate was created."
        )
    token = jwt_from_env()
    certificate_id, certificate_der = fetch_distribution_certificate(token)
    if certificate_id != DISTRIBUTION_CERTIFICATE_ID:
        raise SystemExit(
            "Refusing to sign with a certificate other than "
            f"{DISTRIBUTION_CERTIFICATE_ID}. No certificate was created."
        )
    assert_keychain_has_certificate(argv["keychain"], certificate_der)
    identity = signing_identity_setting(argv["keychain"])
    profiles, included = list_app_store_profiles(token)
    installed = []
    for bundle_id in bundles:
        resource_id = ensure_bundle_id(token, bundle_id, bundle_display_name(bundle_id))
        profile_id, profile_name, raw = ensure_profile(
            token, bundle_id, resource_id, certificate_id, profiles, included
        )
        install_profile(raw, profile_id, profiles_dir)
        installed.append((bundle_id, profile_name))
    patched = patch_pbxproj(text, argv["team"], argv["keychain"], installed, identity)
    if patched.count("CODE_SIGN_STYLE = Manual;") < 1:
        raise SystemExit("Could not set manual signing on the app target. No certificate was created.")
    if identity not in patched:
        raise SystemExit("Could not set the distribution identity. No certificate was created.")
    project.write_text(patched)
    write_export_options(Path(argv["export_plist"]), argv["team"], installed, identity)
    print(
        f"Manual signing uses the shared certificate {DISTRIBUTION_CERTIFICATE_ID}.",
        flush=True,
    )


def self_test():
    der_roundtrip()
    jwt_roundtrip()
    pbxproj_roundtrip()
    export_roundtrip()
    forbidden_roundtrip()
    bundles_roundtrip()
    profile_roundtrip()
    no_certificate_minting()
    print("asc signing ok")


def der_roundtrip():
    raw = bytes(range(32)) + bytes(range(32, 64))
    # Make the high bit set so the DER form needs a leading zero.
    raw = b"\x80" + raw[1:32] + b"\x7f" + raw[33:]
    der = raw_to_der(raw)
    if der_to_raw(der) != raw:
        raise SystemExit("DER signature roundtrip failed")


def jwt_roundtrip():
    with tempfile.TemporaryDirectory() as directory:
        key_path = Path(directory) / "key.pem"
        created = subprocess.run(
            [
                "openssl",
                "ecparam",
                "-name",
                "prime256v1",
                "-genkey",
                "-noout",
                "-out",
                str(key_path),
            ],
            capture_output=True,
            check=False,
        )
        if created.returncode != 0:
            raise SystemExit("Could not generate a test signing key.")
        pem = key_path.read_bytes()
        token = make_jwt(pem, "KEYID1234", "issuer-id", 1_700_000_000)
        header_text, payload_text, signature_text = token.split(".")
        header = json.loads(b64url_decode(header_text))
        payload = json.loads(b64url_decode(payload_text))
        if header.get("alg") != "ES256" or header.get("kid") != "KEYID1234":
            raise SystemExit("JWT header was not ES256")
        if payload.get("aud") != "appstoreconnect-v1" or payload.get("iss") != "issuer-id":
            raise SystemExit("JWT audience was not appstoreconnect-v1")
        if b"BEGIN PRIVATE KEY" in token.encode() or b"BEGIN EC PRIVATE KEY" in token.encode():
            raise SystemExit("JWT included the private key")
        public_path = Path(directory) / "pub.pem"
        extracted = subprocess.run(
            ["openssl", "ec", "-pubout", "-in", str(key_path), "-out", str(public_path)],
            capture_output=True,
            check=False,
        )
        if extracted.returncode != 0:
            raise SystemExit("Could not read the test public key.")
        signature = raw_to_der(b64url_decode(signature_text))
        signature_path = Path(directory) / "sig.der"
        signature_path.write_bytes(signature)
        verified = subprocess.run(
            [
                "openssl",
                "dgst",
                "-sha256",
                "-verify",
                str(public_path),
                "-signature",
                str(signature_path),
            ],
            input=f"{header_text}.{payload_text}".encode(),
            capture_output=True,
            check=False,
        )
        if verified.returncode != 0:
            raise SystemExit("JWT signature did not verify")


def pbxproj_roundtrip():
    fixture = """
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tDEVELOPMENT_TEAM = EXAMPLETEAM;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks;
\t\t};
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks.tests;
\t\t};
\t\tbuildSettings = {
\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks.uitests;
\t\t};
"""
    patched = patch_pbxproj(fixture, "EXAMPLETEAM", "/tmp/signing.keychain-db", TARGETS)
    if 'PRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks;' not in patched:
        raise SystemExit("pbxproj lost the iOS bundle id")
    if patched.count("CODE_SIGN_STYLE = Manual;") != 1:
        raise SystemExit("pbxproj did not set manual signing on the app")
    if 'PROVISIONING_PROFILE_SPECIFIER = "LOJO Networks App Store";' not in patched:
        raise SystemExit("pbxproj missed the iOS profile name")
    if "com.lojo.PrivateNetworks.tests" not in patched or patched.count("CODE_SIGN_STYLE = Automatic;") != 2:
        raise SystemExit("pbxproj changed a test bundle")
    if "Apple Distribution" not in patched or "/tmp/signing.keychain-db" not in patched:
        raise SystemExit("pbxproj missed the distribution identity or keychain")


def export_roundtrip():
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "ExportOptions.plist"
        write_export_options(path, "EXAMPLETEAM", TARGETS)
        with path.open("rb") as handle:
            payload = plistlib.load(handle)
        if payload["method"] != "app-store-connect" or payload["signingStyle"] != "manual":
            raise SystemExit("export options were not manual app-store-connect")
        if payload["signingCertificate"] != "Apple Distribution":
            raise SystemExit("export options missed Apple Distribution")
        if payload["destination"] != "upload" or payload["manageAppVersionAndBuildNumber"] is not False:
            raise SystemExit("export options did not keep the build number or upload destination")
        profiles = payload["provisioningProfiles"]
        if profiles.get("com.lojo.PrivateNetworks") != "LOJO Networks App Store":
            raise SystemExit("export options missed the iOS profile")
        if len(profiles) != 1:
            raise SystemExit("export options included unexpected profiles")


def forbidden_roundtrip():
    held = sys.stderr
    captured = io.StringIO()
    sys.stderr = captured
    try:
        stop_api(
            403,
            '{"errors":[{"status":"403","code":"FORBIDDEN_ERROR","detail":"The resource is not allowed."}]}',
            "certificate",
        )
    except SystemExit as error:
        if error.code != 1:
            raise SystemExit("forbidden path did not stop")
    else:
        raise SystemExit("forbidden path did not stop")
    finally:
        sys.stderr = held
    text = captured.getvalue()
    if "FORBIDDEN_ERROR" not in text or "The resource is not allowed." not in text:
        raise SystemExit("forbidden path did not keep the API response")
    if "Nothing was revoked" not in text or "Admin" not in text:
        raise SystemExit("forbidden path did not say to stop")
    limit = io.StringIO()
    sys.stderr = limit
    try:
        stop_api(
            409,
            "You have already reached the maximum number of certificates of this type.",
            "certificate",
        )
    except SystemExit:
        pass
    finally:
        sys.stderr = held
    if "Nothing was revoked" not in limit.getvalue() or "certificate limit" not in limit.getvalue():
        raise SystemExit("certificate limit was not reported clearly")


def bundles_roundtrip():
    fixture = """
AABBCCDDEEFF001122334455 /* Debug */ = {
	isa = XCBuildConfiguration;
	buildSettings = {
		PRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks;
	};
	name = Debug;
};
11223344556677889900AABB /* Release */ = {
	isa = XCBuildConfiguration;
	buildSettings = {
		PRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks.Widget;
	};
	name = Release;
};
99AABBCCDDEEFF0011223344 /* Debug */ = {
	isa = XCBuildConfiguration;
	buildSettings = {
		PRODUCT_BUNDLE_IDENTIFIER = com.lojo.PrivateNetworks.tests;
	};
	name = Debug;
};
5566778899AABBCCDDEEFF00 /* Build configuration list for PBXNativeTarget "LojoNetworks" */ = {
	isa = XCConfigurationList;
	buildConfigurations = (
		AABBCCDDEEFF001122334455 /* Debug */,
	);
	defaultConfigurationIsVisible = 0;
};
66778899AABBCCDDEEFF0011 /* Build configuration list for PBXNativeTarget "Widget" */ = {
	isa = XCConfigurationList;
	buildConfigurations = (
		11223344556677889900AABB /* Release */,
	);
};
778899AABBCCDDEEFF001122 /* Build configuration list for PBXNativeTarget "Tests" */ = {
	isa = XCConfigurationList;
	buildConfigurations = (
		99AABBCCDDEEFF0011223344 /* Debug */,
	);
};
DEADBEEFDEADBEEFDEADBEEF /* LojoNetworks */ = {
	isa = PBXNativeTarget;
	buildConfigurationList = 5566778899AABBCCDDEEFF00 /* Build configuration list for PBXNativeTarget "LojoNetworks" */;
	name = LojoNetworks;
	productType = "com.apple.product-type.application";
};
CAFEBABECAFEBABECAFEBABE /* Widget */ = {
	isa = PBXNativeTarget;
	buildConfigurationList = 66778899AABBCCDDEEFF0011;
	name = Widget;
	productType = "com.apple.product-type.app-extension";
};
FEEDFACEFEEDFACEFEEDFACE /* Tests */ = {
	isa = PBXNativeTarget;
	buildConfigurationList = 778899AABBCCDDEEFF001122;
	name = Tests;
	productType = "com.apple.product-type.bundle.unit-test";
};
"""
    bundles = distribution_bundles(fixture)
    if bundles != [APP_BUNDLE_ID, "com.lojo.PrivateNetworks.Widget"]:
        raise SystemExit("bundle discovery missed the app or an extension: " + repr(bundles))


def profile_roundtrip():
    """Fetch a profile tied to the shared certificate, or create one. Never mint a certificate."""
    der = b"shared-cert"
    content = base64.b64encode(der).decode()
    profile_body = base64.b64encode(b"profile-bytes").decode()
    calls = []

    def certificate_payload():
        return {
            "data": {
                "id": DISTRIBUTION_CERTIFICATE_ID,
                "attributes": {
                    "certificateType": "IOS_DISTRIBUTION",
                    "certificateContent": content,
                },
            }
        }

    def profile_item(profile_id, bundle_resource_id):
        return {
            "type": "profiles",
            "id": profile_id,
            "attributes": {
                "name": "LOJO Networks App Store",
                "profileType": PROFILE_TYPE,
                "profileState": "ACTIVE",
                "expirationDate": "2099-01-01T00:00:00Z",
                "profileContent": profile_body,
            },
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_resource_id}},
                "certificates": {
                    "data": [{"type": "certificates", "id": DISTRIBUTION_CERTIFICATE_ID}]
                },
            },
        }

    def fake_api(token, method, path, payload=None):
        calls.append((method, path, payload))
        if method == "GET" and path == "/v1/certificates/" + DISTRIBUTION_CERTIFICATE_ID:
            return 200, json.dumps(certificate_payload())
        if method == "GET" and path.startswith("/v1/bundleIds?"):
            return 200, json.dumps({
                "data": [{
                    "id": "BUNDLE",
                    "attributes": {"identifier": APP_BUNDLE_ID},
                }]
            })
        if method == "GET" and path.startswith("/v1/profiles"):
            if calls and any(item[0] == "POST" and item[1] == "/v1/profiles" for item in calls):
                return 200, json.dumps({"data": []})
            return 200, json.dumps({
                "data": [profile_item("PROF1", "BUNDLE")],
                "included": [{
                    "type": "bundleIds",
                    "id": "BUNDLE",
                    "attributes": {"identifier": APP_BUNDLE_ID},
                }],
            })
        if method == "POST" and path == "/v1/profiles":
            return 201, json.dumps({"data": profile_item("PROF2", "BUNDLE")})
        return 404, "{}"

    real_api = globals()["api"]
    globals()["api"] = fake_api
    try:
        cert_id, fetched = fetch_distribution_certificate("token")
        if cert_id != DISTRIBUTION_CERTIFICATE_ID or fetched != der:
            raise SystemExit("shared certificate lookup failed")
        profiles, included = list_app_store_profiles("token")
        profile_id, name, raw = ensure_profile(
            "token", APP_BUNDLE_ID, "BUNDLE", DISTRIBUTION_CERTIFICATE_ID, profiles, included
        )
        if profile_id != "PROF1" or name != "LOJO Networks App Store" or raw != b"profile-bytes":
            raise SystemExit("did not reuse the profile tied to the shared certificate")
        if any(method == "POST" and path == "/v1/certificates" for method, path, _payload in calls):
            raise SystemExit("profile fetch created a certificate")
        if any(method == "DELETE" and "/v1/certificates" in path for method, path, _payload in calls):
            raise SystemExit("profile fetch deleted a certificate")
        calls.clear()
        profile_id, name, raw = ensure_profile(
            "token", APP_BUNDLE_ID, "BUNDLE", DISTRIBUTION_CERTIFICATE_ID, [], {}
        )
        if profile_id != "PROF2":
            raise SystemExit("did not create a profile when none matched the shared certificate")
        created = [payload for method, path, payload in calls if method == "POST" and path == "/v1/profiles"]
        if len(created) != 1:
            raise SystemExit("profile create was not a single request")
        certs = created[0]["data"]["relationships"]["certificates"]["data"]
        if certs != [{"type": "certificates", "id": DISTRIBUTION_CERTIFICATE_ID}]:
            raise SystemExit("created profile was not tied to the shared certificate")
        if any(method == "POST" and path == "/v1/certificates" for method, path, _payload in calls):
            raise SystemExit("profile create minted a certificate")
    finally:
        globals()["api"] = real_api
    sample = "  1) " + hashlib.sha1(der).hexdigest().upper() + ' "Apple Distribution: Example (TEAM)"'
    if not identity_text_matches(sample, der):
        raise SystemExit("identity hash did not match the shared certificate")
    if identity_text_matches(sample, b"other"):
        raise SystemExit("identity hash matched a different certificate")


def no_certificate_minting():
    source = Path(__file__).read_text()
    blocked = (
        "def " + "create_certificate",
        "def " + "revoke_",
        "BEGIN CERTIFICATE " + "REQUEST",
        '"POST", ' + '"/v1/certificates"',
        '"DELETE", ' + '"/v1/certificates',
    )
    for needle in blocked:
        if needle in source:
            raise SystemExit("signing script still contains certificate creation")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    if len(sys.argv) > 1 and sys.argv[1] == "prepare":
        required = (
            "profiles_dir",
            "team",
            "keychain",
            "pbxproj",
            "export_plist",
        )
        values = {}
        args = sys.argv[2:]
        index = 0
        while index < len(args):
            name = args[index][2:].replace("-", "_")
            if index + 1 >= len(args):
                raise SystemExit("Missing a signing argument.")
            values[name] = args[index + 1]
            index += 2
        missing = [name for name in required if name not in values]
        if missing:
            raise SystemExit("Missing signing arguments.")
        prepare(values)
        return
    raise SystemExit("Usage: asc_signing.py --self-test | prepare")


if __name__ == "__main__":
    main()
