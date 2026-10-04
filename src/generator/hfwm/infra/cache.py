"""Generic TTL-aware JSON file cache."""

from __future__ import annotations

import json
import time
from pathlib import Path


class CachedFile:
    """A simple file-based cache backed by a JSON file with TTL validation."""

    def __init__(self, path: Path, ttl_days: float):
        self.path = path
        self.ttl_days = ttl_days

    def load_or_none(self) -> tuple[dict | list | None, float]:
        """Return ``(data, age_days)``; *data* is None if absent or stale."""
        if not self.path.is_file():
            return None, 0
        age_days = (time.time() - self.path.stat().st_mtime) / 86400
        if age_days > self.ttl_days:
            return None, age_days
        try:
            data = json.loads(self.path.read_text("utf-8"))
            return data, age_days
        except (json.JSONDecodeError, KeyError, IndexError):
            return None, age_days

    def save(self, data: dict | list) -> None:
        """Write *data* to the cache file as compact JSON."""
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(data, separators=(",", ":")), encoding="utf-8",
        )

    def discard(self) -> None:
        """Delete the cache file, if there is one."""
        if self.path.is_file():
            self.path.unlink()
