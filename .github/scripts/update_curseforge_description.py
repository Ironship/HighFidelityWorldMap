#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path
from urllib import request, error

REPO_ROOT = Path(__file__).resolve().parents[2]
DESCRIPTION_PATH = REPO_ROOT / "docs" / "DESCRIPTION.md"


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)
    raise SystemExit(1)


def build_request(url: str, payload: dict, token: str):
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "Authorization": f"Bearer {token}",
    }
    return request.Request(url, data=data, headers=headers, method="PATCH")


def main() -> None:
    token = os.environ.get("CF_API_TOKEN")
    if not token:
        fail("CF_API_TOKEN is required.")

    mod_id = os.environ.get("CF_MOD_ID", "1701034").strip()
    if not mod_id:
        fail("CF_MOD_ID is required.")

    raw_description = DESCRIPTION_PATH.read_text(encoding="utf-8")
    if not raw_description.strip():
        fail(f"DESCRIPTION at {DESCRIPTION_PATH} is empty.")

    base_url = os.environ.get("CF_API_BASE", "https://api.curseforge.com/v1")
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


if __name__ == "__main__":
    main()
