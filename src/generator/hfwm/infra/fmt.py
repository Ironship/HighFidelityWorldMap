"""Small formatting utilities."""

from __future__ import annotations


def format_size(num_bytes: float) -> str:
    """Human-readable byte size (e.g. ``"1.2 MB"``)."""
    for unit in ("B", "KB", "MB", "GB"):
        if abs(num_bytes) < 1024:
            return f"{num_bytes:.1f} {unit}"
        num_bytes /= 1024
    return f"{num_bytes:.1f} TB"


def format_time(seconds: float) -> str:
    """Human-readable duration (e.g. ``"5m30s"``)."""
    if seconds < 60:
        return f"{seconds:.0f}s"
    m, s = divmod(int(seconds), 60)
    return f"{m}m{s:02d}s"
