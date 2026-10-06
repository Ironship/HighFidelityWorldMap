"""Emit CaveTiles.lua: baked cave floors/pieces as placements of the client's tiles.

Experiment (branch reuse-game-assets).  The baked cave art (WorldMap/<Cave>/*.blp)
is built from Blizzard's per-room WMO minimap tiles: each cropped to its
opaque content, placed at its MOGI bounding box (1.993 px/unit), and the
whole canvas rotated by (placement yaw - 90) with expand=True.  Every one of
those tiles is a real game file, so instead of shipping the composite, record
where each tile lands and let CaveRenderer.lua draw the client's own copies.

The geometry is the bake's own (bake.py / compose.py / fetch.py), so the
result lines up with the shipped BLPs.  Keys are the synthetic FDIDs
CaveData.lua already uses for those BLPs; nothing there changes.

    python3 scripts/emit_cave_tiles.py              # every discovered mine
    python3 scripts/emit_cave_tiles.py fargodeep    # just those MINES keys

Each entry: { w, h, a, l = { {fdid, srcW, srcH, x0, y0, w, h, cx, cy}, ... } }
  w,h  final (rotated) canvas size       a   rotation applied, degrees (PIL CCW)
  l    leaves in paint order: draw region (x0,y0,w,h) of the srcW x srcH
       texture, centred at (cx,cy) in the final canvas, rotated by a.
"""

import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from PIL import Image  # noqa: E402

from hfwm.caves.bake import _load_groups, _shared_canvas  # noqa: E402
from hfwm.caves.compose import (  # noqa: E402
    MINIMAP_PX_PER_UNIT,
    split_floors_by_height,
    world_align_rotation_degrees,
)
from hfwm.caves.fetch import (  # noqa: E402
    WMO_SUBTILE_PX,
    _cached_path,
    fetch_group_tile,
    fetch_wmo_world_placement,
)
from hfwm.caves.mines import MINES  # noqa: E402
from hfwm.config.paths import WMO_TILE_CACHE_DIR  # noqa: E402

OUT = ROOT.parent / "addon" / "mapdata" / "CaveTiles.lua"


def group_leaves(tile_fdid):
    """Source rectangles making up one WMO group's (cropped) tile.

    Mirrors fetch_tile / fetch_stitched_tile: the room is cropped to the
    bounding box of its opaque pixels.  Returns ``(w, h, leaves)`` with
    ``w x h`` the cropped size and each leaf
    ``(fdid, srcW, srcH, x0, y0, w, h, offX, offY)`` -- a region of one
    texture and where its top-left sits inside the cropped tile.
    """
    if not isinstance(tile_fdid, dict):
        img = Image.open(_cached_path(tile_fdid, WMO_TILE_CACHE_DIR)).convert("RGBA")
        bbox = img.split()[-1].getbbox() or (0, 0) + img.size
        return (bbox[2] - bbox[0], bbox[3] - bbox[1],
                [(tile_fdid, img.width, img.height, bbox[0], bbox[1],
                  bbox[2] - bbox[0], bbox[3] - bbox[1], 0, 0)])

    px = WMO_SUBTILE_PX
    rows = max(r for r, _ in tile_fdid) + 1
    cols = max(c for _, c in tile_fdid) + 1
    canvas = Image.new("RGBA", (cols * px, rows * px), (0, 0, 0, 0))
    sizes = {}
    for (r, c), f in tile_fdid.items():
        sub = Image.open(_cached_path(f, WMO_TILE_CACHE_DIR)).convert("RGBA")
        sizes[(r, c)] = sub.size
        canvas.paste(sub, (c * px, r * px))
    bbox = canvas.split()[-1].getbbox() or (0, 0) + canvas.size
    leaves = []
    for (r, c), f in sorted(tile_fdid.items()):
        ix0, iy0 = max(bbox[0], c * px), max(bbox[1], r * px)
        ix1, iy1 = min(bbox[2], (c + 1) * px), min(bbox[3], (r + 1) * px)
        if ix1 <= ix0 or iy1 <= iy0:
            continue
        leaves.append((f, *sizes[(r, c)], ix0 - c * px, iy0 - r * px,
                       ix1 - ix0, iy1 - iy0, ix0 - bbox[0], iy0 - bbox[1]))
    return bbox[2] - bbox[0], bbox[3] - bbox[1], leaves


def mine_entries(spec):
    """Yield ``(synthetic_fdid, entry_dict)`` for every floor and piece."""
    groups = _load_groups(spec)
    by_index = {g.index: g for g in groups}
    tiled = sorted(i for i in by_index if by_index[i].tile_fdid is not None)
    tiles = {i: fetch_group_tile(by_index[i].tile_fdid) for i in tiled}
    scale = MINIMAP_PX_PER_UNIT
    minx, maxy, w0, h0 = _shared_canvas(by_index, tiled, tiles, scale)

    placement = fetch_wmo_world_placement(
        spec.adt_obj0_fdid, spec.wmo_fdid, spec.modf_unique_id)
    angle = world_align_rotation_degrees(placement.rotation[1])
    w1, h1 = Image.new("RGBA", (w0, h0)).rotate(angle, expand=True).size
    cos, sin = math.cos(math.radians(angle)), math.sin(math.radians(angle))

    def placed(idx):
        g = by_index[idx]
        x1, _, _, _, y2, _ = g.bbox
        gx, gy = round((x1 - minx) * scale), round((maxy - y2) * scale)
        _, _, leaves = group_leaves(g.tile_fdid)
        out = []
        for f, sw, sh, x0, y0, w, h, ox, oy in leaves:
            dx, dy = gx + ox + w / 2 - w0 / 2, gy + oy + h / 2 - h0 / 2
            out.append([f, sw, sh, x0, y0, w, h,
                        round(w1 / 2 + dx * cos + dy * sin, 2),
                        round(h1 / 2 - dx * sin + dy * cos, 2)])
        return out

    if spec.single_floor:
        floors = {"floor": sorted(tiled)}
    else:
        lower, upper = split_floors_by_height(groups)
        floors = {"upper": upper, "lower": lower}
    for i, name in enumerate(floors):
        leaves = [leaf for idx in floors[name] for leaf in placed(idx)]
        yield spec.floor_fdid_base + i, {"w": w1, "h": h1, "a": angle, "l": leaves}
    for order, idx in enumerate(tiled):
        yield spec.piece_fdid_base + order, {
            "w": w1, "h": h1, "a": angle, "l": placed(idx)}


def lua_entry(fdid, e):
    leaves = ",".join("{" + ",".join(f"{v:g}" for v in leaf) + "}" for leaf in e["l"])
    return f"    [{fdid}]={{w={e['w']},h={e['h']},a={e['a']:g},l={{{leaves}}}}},"


def main(only):
    lines = ["-- Auto-generated by scripts/emit_cave_tiles.py - DO NOT EDIT",
             "-- Baked cave floors/pieces as placements of the client's own WMO minimap tiles.",
             "HFWMF_CAVE_TILES = {"]
    done = 0
    for key, spec in MINES.items():
        if only and key not in only:
            continue
        try:
            entries = list(mine_entries(spec))
        except (ValueError, TypeError) as exc:
            print(f"skip {key}: {exc}")
            continue
        lines.append(f"    -- {spec.key}")
        lines += [lua_entry(f, e) for f, e in entries]
        done += 1
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n")
    print(f"{done} mines -> {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main(set(sys.argv[1:]))
