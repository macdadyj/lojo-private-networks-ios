#!/usr/bin/env python3
"""Print App Store Connect buildUploads state and validation errors.

Does not print API keys, tokens, certificate contents, or upload URLs.
"""

import importlib.util
import json
import os
import sys
import urllib.parse
from pathlib import Path

BUNDLE_ID = "com.lojo.PrivateNetworks"
HERE = Path(__file__).resolve().parent


def load_signing():
    spec = importlib.util.spec_from_file_location("asc_signing", HERE / "asc_signing.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load_signing()


def show(text):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()


def parsed(status, body, context):
    try:
        data = json.loads(body) if body else {}
    except json.JSONDecodeError:
        signing.stop_api(status, body, context)
    if status not in (200, 201):
        signing.stop_api(status, body or f"HTTP {status}", context)
    return data


def find_app(token):
    query = urllib.parse.urlencode({"filter[bundleId]": BUNDLE_ID, "limit": "5"})
    status, body = signing.api(token, "GET", "/v1/apps?" + query)
    data = parsed(status, body, "app lookup")
    for item in data.get("data", []):
        if (item.get("attributes") or {}).get("bundleId") == BUNDLE_ID:
            return item["id"]
    sys.stderr.write(f"No App Store Connect app for {BUNDLE_ID}.\n")
    raise SystemExit(1)


def list_uploads(token, app_id):
    path = f"/v1/apps/{app_id}/buildUploads?limit=50"
    uploads = []
    while path:
        status, body = signing.api(token, "GET", path)
        if status == 404 and not uploads:
            query = urllib.parse.urlencode({"limit": "50"})
            status, body = signing.api(token, "GET", "/v1/buildUploads?" + query)
        data = parsed(status, body, "build uploads")
        uploads.extend(data.get("data") or [])
        next_link = ((data.get("links") or {}).get("next")) or ""
        if next_link.startswith("https://api.appstoreconnect.apple.com"):
            path = next_link.split("https://api.appstoreconnect.apple.com", 1)[1]
        else:
            path = ""
        if len(uploads) >= 200:
            break
    return uploads


def upload_detail(token, upload_id):
    status, body = signing.api(token, "GET", f"/v1/buildUploads/{upload_id}")
    return parsed(status, body, "build upload")


def file_errors(token, upload_id):
    status, body = signing.api(token, "GET", f"/v1/buildUploads/{upload_id}/buildUploadFiles?limit=20")
    if status == 404:
        return []
    data = parsed(status, body, "build upload files")
    lines = []
    for item in data.get("data") or []:
        attributes = item.get("attributes") or {}
        delivery = attributes.get("assetDeliveryState") or {}
        name = attributes.get("fileName") or attributes.get("assetType") or "file"
        state = delivery.get("state")
        if state:
            lines.append(f"file {name} delivery={state}")
        for label, group in (("error", delivery.get("errors")), ("warning", delivery.get("warnings"))):
            for detail in group or []:
                lines.append(f"  file {label} {format_detail(detail)}")
    return lines


def format_detail(detail):
    if not isinstance(detail, dict):
        return str(detail)
    code = detail.get("code") or ""
    description = detail.get("description") or ""
    if code and description:
        return f"{code}: {description}"
    return code or description


def lines_for(upload):
    attributes = upload.get("attributes") or {}
    state = attributes.get("state") or {}
    if isinstance(state, str):
        name, errors, warnings, infos = state, [], [], []
    else:
        name = state.get("state")
        errors = state.get("errors") or []
        warnings = state.get("warnings") or []
        infos = state.get("infos") or []
    version = attributes.get("cfBundleVersion")
    short = attributes.get("cfBundleShortVersionString")
    platform = attributes.get("platform")
    uploaded = attributes.get("uploadedDate")
    rows = [
        f"upload version={version} short={short} platform={platform} state={name} uploaded={uploaded}"
    ]
    for label, group in (("error", errors), ("warning", warnings), ("info", infos)):
        for detail in group:
            rows.append(f"  {label} {format_detail(detail)}")
    return rows


def interesting(upload):
    attributes = upload.get("attributes") or {}
    version = str(attributes.get("cfBundleVersion") or "")
    state = attributes.get("state") or {}
    name = state if isinstance(state, str) else state.get("state")
    if version.isdigit() and int(version) >= 32:
        return True
    return name in ("FAILED", "PROCESSING", "AWAITING_UPLOAD")


def report(uploads, details, files):
    shown = 0
    for upload in uploads:
        if not interesting(upload):
            continue
        shown += 1
        upload_id = upload.get("id")
        current = details.get(upload_id) or upload
        for row in lines_for(current):
            show(row)
        for row in files.get(upload_id) or []:
            show(row)
    if shown == 0:
        show("no build upload at version 32 or later, and none failed or processing")
        for upload in uploads[:10]:
            for row in lines_for(upload):
                show(row)


def self_test():
    sample = {
        "attributes": {
            "cfBundleVersion": "38",
            "cfBundleShortVersionString": "1.2",
            "platform": "IOS",
            "uploadedDate": "2026-10-17T11:48:39Z",
            "state": {
                "state": "FAILED",
                "errors": [{"code": "ITMS-90683", "description": "Missing purpose string."}],
                "warnings": [],
                "infos": [],
            },
        }
    }
    text = "\n".join(lines_for(sample))
    if "ITMS-90683" not in text or "version=38" not in text:
        raise SystemExit("self-test did not print the upload error")
    if "assetToken" in text or "BEGIN PRIVATE" in text:
        raise SystemExit("self-test printed a secret")
    show("asc build uploads: ok")


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        self_test()
        return
    missing = [name for name in ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_P8") if not os.environ.get(name)]
    if missing:
        sys.stderr.write("Missing GitHub secret " + ", ".join(missing) + ".\n")
        raise SystemExit(1)
    key_file = None
    if not os.environ.get("KEY_PATH"):
        handle = tempfile.NamedTemporaryFile(prefix="AuthKey_", suffix=".p8", delete=False)
        handle.close()
        key_file = handle.name
        os.environ["KEY_PATH"] = key_file
        # Reuse the uploader's key decoder.
        spec = importlib.util.spec_from_file_location("asc_testflight", HERE / "asc_testflight.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        module.write_key(key_file)
    try:
        token = signing.jwt_from_env()
        app_id = find_app(token)
        uploads = list_uploads(token, app_id)
        show(f"build upload count={len(uploads)}")
        details = {}
        files = {}
        for upload in uploads:
            if not interesting(upload):
                continue
            upload_id = upload.get("id")
            if not upload_id:
                continue
            token = signing.jwt_from_env()
            payload = upload_detail(token, upload_id)
            details[upload_id] = (payload.get("data") or upload)
            files[upload_id] = file_errors(token, upload_id)
        report(uploads, details, files)
    finally:
        if key_file:
            Path(key_file).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
