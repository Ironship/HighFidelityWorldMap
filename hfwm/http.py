"""HTTP helpers for CASC / wago.tools / GitHub downloads."""

from __future__ import annotations

import csv
import io
from pathlib import Path
from urllib.request import Request, urlopen

from .constants import USER_AGENT, WAGO_CASC_FMT


def fetch_url(url: str, *, timeout: int = 60) -> bytes:
    """Simple HTTP GET with User-Agent header."""
    req = Request(url, headers={"User-Agent": USER_AGENT})
    with urlopen(req, timeout=timeout) as resp:
        return resp.read()


def fetch_csv(url: str) -> list[dict]:
    """Download a CSV from *url* and return rows as dicts."""
    data = fetch_url(url)
    text = data.decode("utf-8", errors="replace")
    return list(csv.DictReader(io.StringIO(text)))


def download_casc(fdid: int) -> bytes:
    """Download a raw file from the CASC endpoint by FileDataID."""
    url = WAGO_CASC_FMT.format(fdid)
    return fetch_url(url, timeout=30)


def download_casc_cached(fdid: int, cache_dir: Path) -> Path:
    """Download a CASC file, caching to *cache_dir*/{fdid}.blp."""
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"{fdid}.blp"
    if path.exists() and path.stat().st_size > 0:
        return path
    data = download_casc(fdid)
    path.write_bytes(data)
    return path
