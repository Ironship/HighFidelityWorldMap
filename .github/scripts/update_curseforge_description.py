#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
from urllib import request, error

REPO_ROOT = Path(__file__).resolve().parents[2]
DESCRIPTION_PATH = REPO_ROOT / "docs" / "DESCRIPTION.md"
LOGO_PATH = REPO_ROOT / "assets" / "images" / "logo.png"


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def build_request(url: str, payload: dict, token: str, method: str = "PATCH"):
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    }
    return request.Request(url, data=data, headers=headers, method=method)


def build_logo_upload_request(url: str, logo_bytes: bytes, filename: str, token: str, field_name: str = "file"):
    boundary = "----HFWM-CurseForge-Boundary"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{field_name}"; filename="{filename}"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode("utf-8") + logo_bytes + f"\r\n--{boundary}--\r\n".encode("utf-8")
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {token}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    return request.Request(url, data=body, headers=headers, method="POST")


def update_description(token: str, mod_id: str, base_url: str) -> None:
    if not DESCRIPTION_PATH.exists():
        print(f"Skipping description update because {DESCRIPTION_PATH} does not exist.")
        return

    raw_description = DESCRIPTION_PATH.read_text(encoding="utf-8")
    if not raw_description.strip():
        fail(f"DESCRIPTION at {DESCRIPTION_PATH} is empty.")

    endpoints = [
        f"{base_url}/mods/{mod_id}",
        f"{base_url}/mods/{mod_id}/description",
    ]
    payloads = [
        {"description": raw_description},
        {"body": raw_description},
        {"markdown": raw_description},
    ]

    last_error = None
    for endpoint in endpoints:
        for payload in payloads:
            try:
                req = build_request(endpoint, payload, token)
                with request.urlopen(req, timeout=60) as response:
                    body = response.read().decode("utf-8", errors="replace")
                    print(f"Updated CurseForge description via {endpoint} (HTTP {response.status}).")
                    print(body[:400])
                    return
            except error.HTTPError as exc:
                last_error = exc
                print(f"HTTP error for {endpoint}: {exc.code} {exc.reason}", file=sys.stderr)
                try:
                    details = exc.read().decode("utf-8", errors="replace")
                    if details:
                        print(details[:800], file=sys.stderr)
                except Exception:
                    pass
            except Exception as exc:  # pragma: no cover - fallback for network or validation errors
                last_error = exc
                print(f"Attempt failed for {endpoint}: {exc}", file=sys.stderr)

    fail(f"All CurseForge description update attempts failed. Last error: {last_error}")


def update_logo(token: str, mod_id: str, base_url: str) -> None:
    if not LOGO_PATH.exists():
        print(f"Skipping logo update because {LOGO_PATH} does not exist.")
        return

    logo_bytes = LOGO_PATH.read_bytes()
    if not logo_bytes:
        fail(f"Logo at {LOGO_PATH} is empty.")

    endpoints = [
        f"{base_url}/mods/{mod_id}/logo",
    ]
    field_names = ["file", "logo", "image"]

    last_error = None
    for endpoint in endpoints:
        for field_name in field_names:
            try:
                req = build_logo_upload_request(endpoint, logo_bytes, LOGO_PATH.name, token, field_name=field_name)
                with request.urlopen(req, timeout=60) as response:
                    body = response.read().decode("utf-8", errors="replace")
                    print(f"Updated CurseForge logo via {endpoint} (HTTP {response.status}).")
                    print(body[:400])
                    return
            except error.HTTPError as exc:
                last_error = exc
                print(f"HTTP error for {endpoint} ({field_name}): {exc.code} {exc.reason}", file=sys.stderr)
                try:
                    details = exc.read().decode("utf-8", errors="replace")
                    if details:
                        print(details[:800], file=sys.stderr)
                except Exception:
                    pass
            except Exception as exc:  # pragma: no cover - fallback for network or validation errors
                last_error = exc
                print(f"Attempt failed for {endpoint} ({field_name}): {exc}", file=sys.stderr)

    fail(f"All CurseForge logo update attempts failed. Last error: {last_error}")


def main() -> None:
    token = os.environ.get("CF_API_TOKEN")
    if not token:
        fail("CF_API_TOKEN is required.")

    mod_id = os.environ.get("CF_MOD_ID", "1701034").strip()
    if not mod_id:
        fail("CF_MOD_ID is required.")

    base_url = os.environ.get("CF_API_BASE", "https://api.curseforge.com/v1")
    update_description(token, mod_id, base_url)
    update_logo(token, mod_id, base_url)


if __name__ == "__main__":
    main()
