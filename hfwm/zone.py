"""Per-zone processing — minimap stitch -> crop -> fit art layer -> BLP.

One zone entry from :mod:`hfwm.db2` becomes one folder of BLP2 tiles
whose geometry matches exactly what the client asks for:

    art layer      layer_w x layer_h   (e.g. 1002x668)
    tile grid      cols x rows         (e.g. 4x3)
    output canvas  cols*tile_w x rows*tile_h  (e.g. 1024x768)

The art layer is pasted into the top-left of the output canvas, so the
last tile column/row is partially black; ``Renderer.lua`` trims it with
``SetTexCoord``, mirroring what the client does with Blizzard's own art.
Getting this wrong does not look broken, it looks *slightly stretched* —
hence the explicit geometry rather than anything inferred from the tile
count.

No inpainting: missing minimap tiles stay black.  That is deliberate
(see CLAUDE.md) — the goal is a stitched-minimap world map, warts and
all.
"""

from __future__ import annotations

import os
from pathlib import Path

from .blp import encode_blp2_bgra
from .constants import (
    MINIMAP_TILE_PX,
    MIN_SOURCE_TILE_PX,
    MIN_STITCH_TILE_PX,
    TILE_WORLD_SIZE,
)


# ---------------------------------------------------------------------------
# Output tile naming
# ---------------------------------------------------------------------------

def tile_filenames(folder: str, count: int) -> list[str]:
    """Return the row-major BLP filenames for a zone's art layer.

    The names are ours to choose — the client never sees them, it only
    follows the ``FileDataID -> texture path`` mapping in ``FDIDMap.lua``
    — so they follow Blizzard's ``zone1.blp``/``zone2.blp`` convention
    purely to keep the output readable.
    """
    stem = folder.lower()
    return [f"{stem}{i + 1}.blp" for i in range(count)]


# ---------------------------------------------------------------------------
# Region stitching
# ---------------------------------------------------------------------------

def _effective_tile_px(region: dict, dst_w: int, dst_h: int) -> int:
    """Choose the per-tile stitch resolution for a region.

    A continent region can span 49x56 WDT tiles.  Stitching that at the
    native 512px/tile is a 25088x28672 RGBA canvas — 2.9 GB — to produce
    a 369x560 patch of a 1002x668 art layer.  So the stitch resolution is
    halved (512 -> 256 -> 128 ...) for as long as it stays at or above
    what the destination rectangle actually needs, with a floor of 32px.

    Powers-of-two divisors of 512 keep tile pasting pixel-exact, and the
    crop maths stays exact because ``px_per_yard`` is derived from the
    same value.
    """
    span_x = region["loc_left"] - region["loc_right"]    # world Y extent
    span_y = region["loc_top"] - region["loc_bottom"]    # world X extent
    if span_x <= 0 or span_y <= 0:
        return MINIMAP_TILE_PX

    needed_pp = max(dst_w / span_x, dst_h / span_y)      # px per yard
    needed_tp = needed_pp * TILE_WORLD_SIZE

    tp = MINIMAP_TILE_PX
    while tp > MIN_STITCH_TILE_PX and (tp // 2) >= needed_tp:
        tp //= 2
    return tp


def _stitch_region(
    region: dict,
    tile_cache: dict[int, Path],
    dst_w: int,
    dst_h: int,
):
    """Stitch one region's minimap tiles and crop to its world bounds.

    Returns ``(cropped_image, stats)`` or ``(None, stats)``.
    """
    from PIL import Image

    tp = _effective_tile_px(region, dst_w, dst_h)
    row_min, row_max = region["row_min"], region["row_max"]
    col_min, col_max = region["col_min"], region["col_max"]
    scols = col_max - col_min + 1
    srows = row_max - row_min + 1

    stitch = Image.new("RGBA", (scols * tp, srows * tp), (0, 0, 0, 255))

    loaded = 0
    upscaled = 0
    too_small = 0
    unreadable = 0
    missing = 0

    for key_str, fdid in region["tiles"].items():
        r, c = (int(x) for x in key_str.split("_"))
        path = tile_cache.get(fdid)
        if not path:
            missing += 1
            continue
        try:
            tile = Image.open(path).convert("RGBA")
        except Exception:
            unreadable += 1
            continue

        w, h = tile.size
        if w < MIN_SOURCE_TILE_PX or h < MIN_SOURCE_TILE_PX:
            # Genuinely unusable placeholder.
            tile.close()
            too_small += 1
            continue
        if (w, h) != (tp, tp):
            # gotchas.md 1.2: some legitimate minimap tiles ship at 256px.
            # Upscale rather than drop them, so a zone never ends up with
            # an unexplained hole.  (Most resizes here are downscales to
            # the region's effective stitch resolution.)
            if w < tp or h < tp:
                upscaled += 1
            tile = tile.resize((tp, tp), Image.LANCZOS)

        stitch.paste(tile, ((c - col_min) * tp, (r - row_min) * tp))
        tile.close()
        loaded += 1

    stats = {
        "loaded": loaded,
        "upscaled": upscaled,
        "too_small": too_small,
        "unreadable": unreadable,
        "missing": missing,
        "cells": scols * srows,
        "stitch_px": tp,
    }

    if loaded == 0:
        stitch.close()
        return None, stats

    # --- Crop to the region's world-space rectangle ---------------------
    # Map vertical axis = world X (loc_top is max X), horizontal = world Y
    # (loc_left is max Y).  Both run in the negative direction across the
    # image, which is why every term is (origin - bound).
    world_origin_x = (32 - row_min) * TILE_WORLD_SIZE
    world_origin_y = (32 - col_min) * TILE_WORLD_SIZE
    px_per_yard = tp / TILE_WORLD_SIZE

    crop_top = (world_origin_x - region["loc_top"]) * px_per_yard
    crop_bottom = (world_origin_x - region["loc_bottom"]) * px_per_yard
    crop_left = (world_origin_y - region["loc_left"]) * px_per_yard
    crop_right = (world_origin_y - region["loc_right"]) * px_per_yard

    sw, sh = stitch.size
    crop_left = max(0, min(crop_left, sw))
    crop_right = max(0, min(crop_right, sw))
    crop_top = max(0, min(crop_top, sh))
    crop_bottom = max(0, min(crop_bottom, sh))

    if crop_right - crop_left < 1 or crop_bottom - crop_top < 1:
        stitch.close()
        stats["degenerate"] = True
        return None, stats

    cropped = stitch.crop((
        int(crop_left), int(crop_top),
        int(round(crop_right)), int(round(crop_bottom)),
    ))
    stitch.close()
    return cropped, stats


# ---------------------------------------------------------------------------
# Zone processing
# ---------------------------------------------------------------------------

def process_zone(
    zone_info: dict,
    tile_cache: dict[int, Path],
    output_dir: str,
) -> dict:
    """Build every BLP tile for one zone."""
    import PIL.Image
    from PIL import Image

    PIL.Image.MAX_IMAGE_PIXELS = None

    folder = zone_info["folder"]
    cols, rows = zone_info["cols"], zone_info["rows"]
    layer_w, layer_h = zone_info["layer_w"], zone_info["layer_h"]
    tile_w, tile_h = zone_info["tile_w"], zone_info["tile_h"]
    tile_fdids = zone_info["tile_fdids"]

    expected = cols * rows
    if len(tile_fdids) != expected:
        return {
            "status": "error",
            "reason": (
                f"tile_fdids has {len(tile_fdids)} entries, "
                f"expected {cols}x{rows}={expected}"
            ),
        }

    layer = Image.new("RGBA", (layer_w, layer_h), (0, 0, 0, 255))

    agg = {"loaded": 0, "upscaled": 0, "too_small": 0,
           "unreadable": 0, "missing": 0, "cells": 0}
    regions_drawn = 0
    notes: list[str] = []
    stitch_px: set[int] = set()

    for region in zone_info["regions"]:
        # Destination sub-rect of the art layer.  UiMin/UiMax index 0 is
        # the horizontal axis (fed by world Y), index 1 the vertical
        # (fed by world X) — verified against UiMap 947, where Kalimdor
        # sits at x 0.04-0.41 and Eastern Kingdoms at x 0.55-0.90.
        dx0 = int(round(region["ui_min_x"] * layer_w))
        dx1 = int(round(region["ui_max_x"] * layer_w))
        dy0 = int(round(region["ui_min_y"] * layer_h))
        dy1 = int(round(region["ui_max_y"] * layer_h))
        dx0, dx1 = max(0, min(dx0, layer_w)), max(0, min(dx1, layer_w))
        dy0, dy1 = max(0, min(dy0, layer_h)), max(0, min(dy1, layer_h))
        if dx1 - dx0 < 1 or dy1 - dy0 < 1:
            notes.append(f"region map {region['map_id']} has empty ui rect")
            continue

        cropped, stats = _stitch_region(
            region, tile_cache, dx1 - dx0, dy1 - dy0,
        )
        for k in agg:
            agg[k] += stats.get(k, 0)
        stitch_px.add(stats.get("stitch_px", 0))
        if cropped is None:
            notes.append(
                f"region map {region['map_id']} produced nothing"
                + (" (degenerate crop)" if stats.get("degenerate") else "")
            )
            continue

        scaled = cropped.resize((dx1 - dx0, dy1 - dy0), Image.LANCZOS)
        cropped.close()
        layer.paste(scaled, (dx0, dy0))
        scaled.close()
        regions_drawn += 1

    if regions_drawn == 0:
        layer.close()
        return {
            "status": "skip",
            "reason": "; ".join(notes) or "no minimap tiles loaded",
        }

    # --- Pad the art layer up to the tile grid --------------------------
    out_w, out_h = cols * tile_w, rows * tile_h
    if (out_w, out_h) != (layer_w, layer_h):
        canvas = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 255))
        canvas.paste(layer, (0, 0))
        layer.close()
        layer = canvas

    # --- Encode BLP tiles, row-major -----------------------------------
    names = tile_filenames(folder, expected)
    zone_dst = os.path.join(output_dir, folder)
    if os.path.isdir(zone_dst):
        for old in os.listdir(zone_dst):
            try:
                os.remove(os.path.join(zone_dst, old))
            except OSError:
                pass
    os.makedirs(zone_dst, exist_ok=True)

    total_bytes = 0
    for i, fname in enumerate(names):
        x0 = (i % cols) * tile_w
        y0 = (i // cols) * tile_h
        piece = layer.crop((x0, y0, x0 + tile_w, y0 + tile_h))
        data = encode_blp2_bgra(piece)
        piece.close()
        with open(os.path.join(zone_dst, fname), "wb") as fp:
            fp.write(data)
        total_bytes += len(data)

    layer.close()

    return {
        "status": "ok",
        "folder": folder,
        "tiles": expected,
        "grid": f"{cols}x{rows}",
        "layer": f"{layer_w}x{layer_h}",
        "output": f"{out_w}x{out_h}",
        "regions": regions_drawn,
        "stitch_px": sorted(p for p in stitch_px if p),
        "files": names,
        "fdids": list(tile_fdids),
        "bytes": total_bytes,
        "minimap": agg,
        "notes": notes,
    }


# ---------------------------------------------------------------------------
# Process-pool job wrapper
# ---------------------------------------------------------------------------

def process_zone_job(job: tuple) -> tuple[str, dict]:
    """Top-level callable for ``ProcessPoolExecutor`` workers."""
    zone_info, tile_cache_str, output_dir = job
    folder = zone_info.get("folder", "?")
    try:
        tile_cache = {int(k): Path(v) for k, v in tile_cache_str.items()}
        return folder, process_zone(zone_info, tile_cache, output_dir)
    except Exception:
        import traceback
        return folder, {"status": "error", "reason": traceback.format_exc()}
