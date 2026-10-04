"""Output tile naming, shared by the zone writer and the FDIDMap generator."""

from __future__ import annotations


def tile_filenames(folder: str, count: int) -> list[str]:
    """Return the row-major BLP filenames for a zone's art layer.

    The names are ours to choose — the client never sees them, it only
    follows the ``FileDataID -> texture path`` mapping in ``FDIDMap.lua``
    — so they follow Blizzard's ``zone1.blp``/``zone2.blp`` convention
    purely to keep the output readable.
    """
    stem = folder.lower()
    return [f"{stem}{i + 1}.blp" for i in range(count)]
