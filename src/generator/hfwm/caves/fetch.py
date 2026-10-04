"""Fetching baked indoor minimap art and the files that place it.

Everything here goes through the *pinned* CASC endpoint: the WMO/ADT files
and the per-group minimap tiles are build-specific, and an unpinned
request would happily serve retail's copy (see
:data:`hfwm.config.endpoints.WAGO_CASC_PINNED_FMT`).
"""

from __future__ import annotations

from pathlib import Path

from PIL import Image

from ..config.paths import WMO_CACHE_DIR, WMO_TILE_CACHE_DIR
from ..infra.http import download_casc_cached
from .wmo import WmoPlacement, parse_modf_placements, select_placement


def _cached_path(fdid: int, cache_dir: Path) -> Path:
    return download_casc_cached(fdid, cache_dir, pinned=True)


def fetch_wmo_root(fdid: int) -> bytes:
    return _cached_path(fdid, WMO_CACHE_DIR).read_bytes()


def fetch_wmo_world_placement(adt_obj0_fdid: int, wmo_fdid: int,
                               expected_unique_id: int | None = None) -> WmoPlacement:
    """Return the MODF placement record (position + rotation) of *wmo_fdid*.

    Only ``rotation.y`` (the yaw about Up, degrees) is used for the flat,
    top-down floor plans this project bakes; pitch/roll (rotation.x /
    rotation.z) are ignored.  wowdev.wiki's ADT/v18 coordinate-system
    table names rotation.y specifically as "the rotation around the Up
    axis" — the only component that can matter for a top-down image.  A
    cave placed with real pitch/roll would need actual 3-D re-projection
    this pipeline doesn't (yet) do; Fargodeep's own record has rotation ==
    (0.0, 301.5, 0.0), i.e. flat, so this isn't exercised here.

    The height component matters too — see
    :func:`hfwm.caves.wmo.world_z_range_for_groups`.
    """
    data = _cached_path(adt_obj0_fdid, WMO_CACHE_DIR).read_bytes()
    placements = parse_modf_placements(data, wmo_fdid)
    return select_placement(placements, wmo_fdid, adt_obj0_fdid, expected_unique_id)


def fetch_tile(fdid: int) -> Image.Image:
    """Fetch one group's minimap tile, cropped to its opaque content.

    Every tile is padded out to a power-of-two texture size (32/64/128px
    square), with the actual room render packed into one corner and the
    rest left fully transparent — a normal texture-atlas constraint, not
    meaningful image content. Left uncropped, that padding was why touching
    rooms rendered with a visible gap between them despite their MOGI
    bboxes having zero coordinate-space gap: each room's real, alpha-cropped
    content aspect ratio matches its bbox aspect ratio closely (verified
    across all 21 Fargodeep tiles, within a few percent each), while the
    padded square does not. Cropping here, once, keeps that fix out of the
    compositing code and applies automatically to any future dungeon.
    """
    img = Image.open(_cached_path(fdid, WMO_TILE_CACHE_DIR)).convert("RGBA")
    opaque_bbox = img.split()[-1].getbbox()
    if opaque_bbox:
        img = img.crop(opaque_bbox)
    return img


# Fixed pixel pitch every WMO-group minimap sub-tile is baked at, confirmed
# across every multi-subtile group seen so far (md_crypt_d, md_warmcave,
# md_junglecave/md_junglecave07, md_mountaincave_medium_h, mini-hive_e, the
# md_hive family): every "_<group>_<row>_<col>.blp" file is exactly 256x256,
# regardless of WMO or group -- the same convention hfwm/config/tiles.py's
# NATIVE_ZONE_TILE_PX documents for outdoor Type=Zone tiles. A room whose
# baked art needs more than one tile is simply several of these pasted
# edge-to-edge, uncropped, before the whole assembled room gets the same
# single alpha-bbox crop fetch_tile() gives a lone tile.
WMO_SUBTILE_PX = 256


def fetch_stitched_tile(subtile_fdids: dict[tuple[int, int], int]) -> Image.Image:
    """Fetch and assemble a group's minimap art from more than one raw
    sub-tile, for a room too large for the single-tile case ``fetch_tile``
    handles.

    Each sub-tile is keyed by its own ``(row, col)`` position in the
    group's local tile grid (from the ``..._<group:03d>_<row:02d>_<col:02d>
    .blp`` filename -- see the package docstring (hfwm/caves/__init__.py)). Unlike ``fetch_tile``,
    individual sub-tiles are pasted *uncropped* at their grid position
    (``col * WMO_SUBTILE_PX, row * WMO_SUBTILE_PX``) — cropping each one
    first would throw away its position within the room, which is exactly
    the information the grid encodes. The alpha-bbox crop ``fetch_tile``
    does is instead applied once, to the fully assembled room, for the
    same reason it's applied there: real room content is opaque, the
    padding around it (now spread across however many sub-tiles border
    the room's edge) is fully transparent.
    """
    max_row = max(r for r, _ in subtile_fdids)
    max_col = max(c for _, c in subtile_fdids)
    canvas = Image.new(
        "RGBA",
        ((max_col + 1) * WMO_SUBTILE_PX, (max_row + 1) * WMO_SUBTILE_PX),
        (0, 0, 0, 0),
    )
    for (row, col), fdid in subtile_fdids.items():
        sub = Image.open(_cached_path(fdid, WMO_TILE_CACHE_DIR)).convert("RGBA")
        canvas.paste(sub, (col * WMO_SUBTILE_PX, row * WMO_SUBTILE_PX))
    opaque_bbox = canvas.split()[-1].getbbox()
    if opaque_bbox:
        canvas = canvas.crop(opaque_bbox)
    return canvas


def fetch_group_tile(tile_fdid: "int | dict[tuple[int, int], int]") -> Image.Image:
    """Dispatch to ``fetch_tile`` or ``fetch_stitched_tile`` depending on
    whether *tile_fdid* (a ``MineSpec.tile_fdids`` value, or the
    ``WmoGroup.tile_fdid`` it ends up on) is a plain FDID or a multi-subtile
    ``{(row, col): fdid}`` map. Every call site that used to call
    ``fetch_tile`` directly goes through this instead, so a group can move
    from single- to multi-subtile without touching the compositing code.
    """
    if isinstance(tile_fdid, dict):
        return fetch_stitched_tile(tile_fdid)
    return fetch_tile(tile_fdid)
