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

A region's world rectangle is *not* guaranteed to lie inside the
terrain's 64x64 tile grid.  Continent maps are bounded to the art
layer's 3:2 aspect, so their eastern edge runs off the grid; the crop
comes back short and the paste rect is shrunk to match (see
``coordinates.compute_crop_box``).  Filling the whole destination with a
short crop is what puts the art out from under the client's zone
highlights.

Nothing here invents terrain.  What the raw stitch does not cover is
decided by the enabled **art passes** (see :mod:`hfwm.effects`, which is
also where the rule that every one of them must be toggleable lives).
Three exist, and they are alternatives:

* ``alpha-sea`` (default) — make the sea and every uncovered cell
  *transparent* and leave it that way.  No backdrop is chosen here at all;
  the addon draws one behind the tiles at runtime, so the same BLPs serve
  every background its options panel offers.
* ``ocean`` — the stitch delivers the sea as several different flat fills
  meeting along tile boundaries, so :mod:`hfwm.ocean` collapses them onto
  one colour and extends it into empty cells that border open water.
  Everything else stays black.  Baked in, and worth it only for that
  cell classification, which a flat runtime backdrop cannot reproduce.
* ``base-art`` — composite the transparent layer over the zone's original
  hand-painted art, so Blizzard's ocean, coastline and parchment border
  are baked in under the satellite terrain.

The first two share their sea handling: ``alpha-sea`` and ``base-art``
both erase it, and differ only in whether anything is put underneath
before the BLPs are written.

With no passes enabled the output is the raw stitch, gaps and seams and
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
    OCEAN_TILE_FRACTION,
    TILE_WORLD_SIZE,
)
from .coordinates import compute_crop_box
from .ocean import classify_missing_cells, erase_tile, unify_tile
from .resample import resize_rgba


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
    sea_mode: str | None = None,
    ocean_rgb: tuple[int, int, int] | None = None,
):
    """Stitch one region's minimap tiles and crop to its world bounds.

    Returns ``(cropped_image, stats)`` or ``(None, stats)``.
    ``stats["coverage"]`` is the fraction of the region's world
    rectangle the crop actually covers — the caller must paste into that
    fraction of the destination rect rather than stretching to fill it.

    *sea_mode* selects what happens to the sea, and comes from whichever
    art pass is enabled:

    ``None``
        Nothing.  The raw stitch, uncovered cells black.
    ``"unify"``
        Every ocean-fill pixel is recoloured to *ocean_rgb*, and empty
        cells that open onto real water are filled with it too.
    ``"erase"``
        Every ocean-fill pixel becomes transparent, and the canvas starts
        transparent so uncovered cells are holes rather than black.  No
        cell classification is needed: with a backdrop to fall through to,
        showing it is the right answer for *every* gap, not just the ones
        that border water.

    Either way the work happens at each tile's native resolution, before
    the downscale to ``tp``.  Afterwards the downscale has already blended
    dark open ocean into light coastal water across every coast tile, and
    no exact-colour match can undo that.
    """
    from PIL import Image

    tp = _effective_tile_px(region, dst_w, dst_h)
    row_min, row_max = region["row_min"], region["row_max"]
    col_min, col_max = region["col_min"], region["col_max"]
    scols = col_max - col_min + 1
    srows = row_max - row_min + 1

    # Transparent base only when something is going to show through it;
    # otherwise the historical opaque black, so a raw run is unchanged.
    base = (0, 0, 0, 0) if sea_mode == "erase" else (0, 0, 0, 255)
    stitch = Image.new("RGBA", (scols * tp, srows * tp), base)

    loaded = 0
    upscaled = 0
    too_small = 0
    unreadable = 0
    missing = 0
    ocean_fracs: dict[tuple[int, int], float] = {}

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
        if sea_mode == "unify":
            tile, ocean_fracs[(r, c)] = unify_tile(tile, ocean_rgb)
        elif sea_mode == "erase":
            tile, ocean_fracs[(r, c)] = erase_tile(tile)
        if (w, h) != (tp, tp):
            # gotchas.md 1.2: some legitimate minimap tiles ship at 256px.
            # Upscale rather than drop them, so a zone never ends up with
            # an unexplained hole.  (Most resizes here are downscales to
            # the region's effective stitch resolution.)
            if w < tp or h < tp:
                upscaled += 1
            # resize_rgba, not Image.resize: an erased sea keeps its colour
            # under alpha 0 and Pillow's premultiplied path would zero it.
            tile = resize_rgba(tile, (tp, tp), Image.LANCZOS)

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
        "coverage": (0.0, 0.0, 1.0, 1.0),
        "ocean_cells": 0,
        "has_ocean": False,
    }

    if loaded == 0:
        stitch.close()
        return None, stats

    # --- Extend the sea into the empty cells ----------------------------
    # Only the ones that actually border open water: an interior map like
    # Alterac Valley bakes its own grey void into its tiles, and painting
    # the gap around it blue just relocates the seam.
    if sea_mode == "unify":
        filled = classify_missing_cells(
            ocean_fracs, row_min, row_max, col_min, col_max,
        )
        for r, c in filled:
            stitch.paste(
                ocean_rgb + (255,),
                (
                    (c - col_min) * tp, (r - row_min) * tp,
                    (c - col_min + 1) * tp, (r - row_min + 1) * tp,
                ),
            )
        stats["ocean_cells"] = len(filled)
        stats["has_ocean"] = bool(filled) or any(
            f >= OCEAN_TILE_FRACTION for f in ocean_fracs.values()
        )
    elif sea_mode == "erase":
        # Nothing to paint — the empty cells are already holes.  Count them
        # so the run still reports how much of the grid the backdrop is
        # carrying.
        stats["ocean_cells"] = stats["cells"] - loaded
        stats["has_ocean"] = any(
            f >= OCEAN_TILE_FRACTION for f in ocean_fracs.values()
        )

    # --- Crop to the region's world-space rectangle ---------------------
    # Map vertical axis = world X (loc_top is max X), horizontal = world Y
    # (loc_left is max Y).  Both run in the negative direction across the
    # image, which is why compute_crop_box works in (origin - bound).
    sw, sh = stitch.size
    box, coverage = compute_crop_box(
        row_min, col_min,
        region["loc_top"], region["loc_bottom"],
        region["loc_left"], region["loc_right"],
        sw, sh, tp,
    )
    stats["coverage"] = coverage

    if box[2] - box[0] < 1 or box[3] - box[1] < 1:
        stitch.close()
        stats["degenerate"] = True
        return None, stats

    cropped = stitch.crop(box)
    stitch.close()
    return cropped, stats


# ---------------------------------------------------------------------------
# Base-art backdrop
# ---------------------------------------------------------------------------

def _base_art_canvas(
    zone_info: dict,
    base_art_cache: dict[int, Path],
    out_w: int,
    out_h: int,
):
    """Reassemble the zone's original hand-painted art as a backdrop.

    ``zone_info["tile_fdids"]`` is already in the row-major order the
    output grid uses — it is the same list the addon remaps — so the
    client's own art layer rebuilds by pasting tile *i* at
    ``(i % cols, i // cols)``, exactly where our tile *i* will go.

    Returns ``(image, missing_count)``, or ``(None, n)`` if not a single
    tile was available.  The result is forced opaque: Blizzard's tiles
    carry alpha of their own, and any transparency left in the backdrop
    would punch a hole straight through the finished BLP.
    """
    from PIL import Image

    cols = zone_info["cols"]
    tile_w, tile_h = zone_info["tile_w"], zone_info["tile_h"]

    canvas = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 255))
    got = 0
    missing = 0
    for i, fdid in enumerate(zone_info["tile_fdids"]):
        path = base_art_cache.get(fdid)
        if not path:
            missing += 1
            continue
        try:
            with Image.open(path) as src:
                art = src.convert("RGBA")
        except Exception:
            missing += 1
            continue
        if art.size != (tile_w, tile_h):
            art = art.resize((tile_w, tile_h), Image.LANCZOS)
        canvas.alpha_composite(art, ((i % cols) * tile_w, (i // cols) * tile_h))
        art.close()
        got += 1

    if not got:
        canvas.close()
        return None, missing
    return canvas, missing


# ---------------------------------------------------------------------------
# Zone processing
# ---------------------------------------------------------------------------

def process_zone(
    zone_info: dict,
    tile_cache: dict[int, Path],
    output_dir: str,
    passes: dict[str, dict] | None = None,
    base_art_cache: dict[int, Path] | None = None,
) -> dict:
    """Build every BLP tile for one zone.

    *passes* is the resolved art-pass settings from
    :func:`hfwm.effects.resolve` — ``{}`` or ``None`` for a raw stitch.
    """
    import PIL.Image
    from PIL import Image

    PIL.Image.MAX_IMAGE_PIXELS = None

    passes = passes or {}
    ocean_opts = passes.get("ocean")
    ocean_rgb = ocean_opts["color"] if ocean_opts else None
    want_base_art = "base-art" in passes
    want_alpha_sea = "alpha-sea" in passes
    # alpha-sea and base-art erase the sea identically; the only difference
    # is whether a backdrop goes under it before the BLPs are written.
    sea_mode = (
        "erase" if (want_base_art or want_alpha_sea)
        else ("unify" if ocean_opts else None)
    )

    folder = zone_info["folder"]
    tile_fdids = zone_info["tile_fdids"]

    # ``native`` (see hfwm/db2.py's _native_zone_geometry) means this is a
    # Type=Zone map whose art layer is sized for the minimap's own source
    # density rather than Blizzard's fixed layer. tile_fdids stays
    # Blizzard's own list -- still used below for the base-art backdrop and
    # for reporting -- but it no longer enumerates the output grid 1:1, so
    # the length assertion in the else-branch doesn't apply here.
    native = zone_info.get("native")
    if native:
        cols, rows = native["cols"], native["rows"]
        layer_w, layer_h = native["layer_w"], native["layer_h"]
        tile_w, tile_h = native["tile_w"], native["tile_h"]
    else:
        cols, rows = zone_info["cols"], zone_info["rows"]
        layer_w, layer_h = zone_info["layer_w"], zone_info["layer_h"]
        tile_w, tile_h = zone_info["tile_w"], zone_info["tile_h"]

    expected = cols * rows
    if not native and len(tile_fdids) != expected:
        return {
            "status": "error",
            "reason": (
                f"tile_fdids has {len(tile_fdids)} entries, "
                f"expected {cols}x{rows}={expected}"
            ),
        }

    # Start fully transparent rather than black.  Every source tile is
    # opaque RGB, so alpha ends up being an exact record of which pixels a
    # region actually covered — which is what lets the background colour be
    # chosen *after* stitching, once it is known whether this zone has any
    # sea in it.  A region's world rect can run past the terrain grid (every
    # continent map does), so on Eastern Kingdoms the rightmost 6% of the
    # art layer is background and has to match the ocean or the seam is
    # right back.
    layer = Image.new("RGBA", (layer_w, layer_h), (0, 0, 0, 0))

    agg = {"loaded": 0, "upscaled": 0, "too_small": 0,
           "unreadable": 0, "missing": 0, "cells": 0, "ocean_cells": 0}
    regions_drawn = 0
    has_ocean = False
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
            region, tile_cache, dx1 - dx0, dy1 - dy0, sea_mode, ocean_rgb,
        )
        for k in agg:
            agg[k] += stats.get(k, 0)
        stitch_px.add(stats.get("stitch_px", 0))
        has_ocean = has_ocean or stats["has_ocean"]
        if cropped is None:
            notes.append(
                f"region map {region['map_id']} produced nothing"
                + (" (degenerate crop)" if stats.get("degenerate") else "")
            )
            continue

        # The crop is clamped to the terrain grid, so it can cover only
        # part of the region's world rectangle.  Shrink the paste rect by
        # the same fractions — anything else rescales the whole map and
        # slides it out from under the client's zone highlights.
        cx0, cy0, cx1, cy1 = stats["coverage"]
        rect_w, rect_h = dx1 - dx0, dy1 - dy0
        px0 = dx0 + int(round(cx0 * rect_w))
        px1 = dx0 + int(round(cx1 * rect_w))
        py0 = dy0 + int(round(cy0 * rect_h))
        py1 = dy0 + int(round(cy1 * rect_h))
        px0, px1 = max(0, px0), min(layer_w, px1)
        py0, py1 = max(0, py0), min(layer_h, py1)
        if px1 - px0 < 1 or py1 - py0 < 1:
            cropped.close()
            notes.append(
                f"region map {region['map_id']} covers no pixels of its "
                f"ui rect after clamping to the terrain grid"
            )
            continue
        if (px0, py0, px1, py1) != (dx0, dy0, dx1, dy1):
            notes.append(
                f"region map {region['map_id']} world bounds run past the "
                f"terrain grid — drawn into "
                f"{px0},{py0}-{px1},{py1} of {dx0},{dy0}-{dx1},{dy1} "
                f"(coverage {cx0:.3f},{cy0:.3f}-{cx1:.3f},{cy1:.3f})"
            )

        scaled = resize_rgba(cropped, (px1 - px0, py1 - py0), Image.LANCZOS)
        cropped.close()
        layer.paste(scaled, (px0, py0))
        scaled.close()
        regions_drawn += 1

    if regions_drawn == 0:
        layer.close()
        return {
            "status": "skip",
            "reason": "; ".join(notes) or "no minimap tiles loaded",
        }

    # --- Flatten onto the backdrop, then pad to the tile grid -----------
    # The backdrop is whatever the enabled art pass says everything the
    # stitch did not cover should be: nothing at all (alpha-sea, which
    # defers the decision to the addon), the zone's original hand-painted
    # art, the unified sea colour, or black.  The padding beyond the art
    # layer is trimmed by ``SetTexCoord`` in Renderer.lua and never visible,
    # but it shares the backdrop so the BLPs stay self-consistent.
    out_w, out_h = cols * tile_w, rows * tile_h
    base_art_used = False
    base_art_missing = 0

    canvas = None
    if want_base_art:
        # _base_art_canvas places Blizzard's original art-layer tiles using
        # zone_info's own (small, fixed) cols/tile_w/tile_h -- that grid is
        # unrelated to the native one above, so build it at its own native
        # size first and upscale the whole composed backdrop afterwards
        # rather than trying to paste small original tiles into a much
        # bigger canvas at the wrong positions.
        orig_w = zone_info["cols"] * zone_info["tile_w"]
        orig_h = zone_info["rows"] * zone_info["tile_h"]
        canvas, base_art_missing = _base_art_canvas(
            zone_info, base_art_cache or {}, orig_w, orig_h,
        )
        if canvas is not None and (orig_w, orig_h) != (out_w, out_h):
            upscaled = resize_rgba(canvas, (out_w, out_h), Image.LANCZOS)
            canvas.close()
            canvas = upscaled
        if canvas is None:
            notes.append(
                "base art unavailable (none of the zone's "
                f"{len(zone_info['tile_fdids'])} original art tiles could be "
                "read) — falling back to a black backdrop"
            )
        else:
            base_art_used = True
            if base_art_missing:
                notes.append(
                    f"{base_art_missing} of "
                    f"{len(zone_info['tile_fdids'])} original art tiles "
                    f"missing — those areas fall back to black"
                )

    if canvas is None:
        if want_alpha_sea:
            # The whole point of this pass: choose nothing.  The canvas stays
            # transparent, the erased sea and the uncovered cells stay holes,
            # and the addon puts something behind the tiles at draw time.
            # BLP2 here is uncompressed BGRA with alphaDepth 8 (see blp.py),
            # so the alpha survives into the shipped file intact.
            canvas = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
        else:
            # Sea if this zone has any, black otherwise, so an interior map
            # like Alterac Valley is left exactly as it was.
            background = (ocean_rgb if ocean_rgb is not None and has_ocean
                          else (0, 0, 0)) + (255,)
            canvas = Image.new("RGBA", (out_w, out_h), background)

    if want_alpha_sea:
        # Plain paste, not alpha_composite.  Compositing would resolve every
        # transparent pixel against the canvas and throw away the sea colour
        # that erase_tile() deliberately left in the RGB channels, which is
        # what keeps the coastline downscaling into sea rather than into
        # black.  There is nothing to composite against anyway: the canvas
        # here is empty by construction.
        canvas.paste(layer, (0, 0))
    else:
        canvas.alpha_composite(layer)
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
        "native": bool(native),
        "regions": regions_drawn,
        "has_ocean": has_ocean,
        "alpha_sea": want_alpha_sea,
        "base_art": base_art_used,
        "base_art_missing": base_art_missing,
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
    """Top-level callable for ``ProcessPoolExecutor`` workers.

    The job tuple is ``(zone_info, tile_cache, output_dir, passes,
    base_art_cache)``.  Both caches arrive with string keys because the
    whole tuple has to pickle across the process boundary, and *passes* is
    plain nested dicts for the same reason.
    """
    (zone_info, tile_cache_str, output_dir, passes,
     base_art_cache_str) = job
    folder = zone_info.get("folder", "?")
    try:
        tile_cache = {int(k): Path(v) for k, v in tile_cache_str.items()}
        base_art_cache = {
            int(k): Path(v) for k, v in (base_art_cache_str or {}).items()
        }
        return folder, process_zone(
            zone_info, tile_cache, output_dir, passes, base_art_cache,
        )
    except Exception:
        import traceback
        return folder, {"status": "error", "reason": traceback.format_exc()}
