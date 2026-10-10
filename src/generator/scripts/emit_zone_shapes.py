"""Emit the zone masks and ZoneShapes.lua for the World/Continent Fog of War.

ZoneFog.lua draws this addon's map only over zones the player has explored in
full, cropping the map to each zone with a mask, so it needs every zone's
outline as an image. The outlines are the game's own: every 33-yard terrain
chunk of every terrain (ADT) tile carries an AreaID, and a zone is the set of
chunks whose area -- or one of its parents -- is the zone's AreaID
(UiMapAssignment).

Per zone this writes ZoneMasks/z<UiMapID>.blp, an alpha mask of the
zone's chunks over its bounding box, smoothed so the one-chunk steps of the
border do not show as a staircase. ZoneShapes.lua records where each mask
goes on each map: the box, in 0-1 map coordinates, found with the same
UiMapAssignment bounds the stitched art uses (hfwm/gamedata/db2.py).

Masks overlap their neighbours by a fraction of a chunk (see EDGE_LOW/HIGH) so
two adjacent explored zones leave no seam between them.

City maps have no overlays of their own and sit inside a zone, so their
chunks are given to the nearest zone.

    python3 scripts/emit_zone_shapes.py

The terrain tiles are downloaded once (a thousand or so requests, 4-5 s each,
run in parallel) and only the 16x16 area table of each is kept in the cache.
"""

import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from emit_zone_overlays import overlay_counts  # noqa: E402
from hfwm.config.paths import CACHE_ROOT, WDT_CACHE_DIR  # noqa: E402
from hfwm.config.tiles import TILE_WORLD_SIZE, UI_MAP_TYPE_ZONE  # noqa: E402
from hfwm.formats.blp import encode_blp2_bgra  # noqa: E402
from hfwm.formats.wdt import parse_wdt_maid  # noqa: E402
from hfwm.gamedata.tables import fetch_pinned_table  # noqa: E402
from hfwm.geometry.coordinates import world_to_tile  # noqa: E402
from hfwm.infra.http import download_casc  # noqa: E402

ADDON = ROOT.parents[0] / "addon" / "client"
OUT = ADDON / "ZoneShapes.lua"
MASK_DIR = ADDON / "ZoneMasks"  # not under WorldMap/, which is regenerated and gitignored
AREA_CACHE = CACHE_ROOT / "adt_areas"

MAPS = (1414, 1415, 947)  # Kalimdor, Eastern Kingdoms, Azeroth (the world map)
MAID_FIELD_ROOT_ADT = 0   # WDT MAID field holding the root ADT's FileDataID
CHUNK = TILE_WORLD_SIZE / 16
CITY_REACH_YARDS = 1500   # how far a city's chunks may borrow a zone from
THREADS = 12

PAD = 3            # chunks of empty border around a zone's box, so the blur fits
SUPERSAMPLE = 4    # working pixels per chunk while smoothing
BLUR_CHUNKS = 1.0  # smoothing radius, in chunks
MIN_PX_PER_CHUNK = 1.0  # mask resolution floor; sizes are rounded up to a power of two
# The smoothed edge (0..1) is stretched between these. Neighbouring zones'
# smoothed edges sum to 1, so a pair of masks that each reach full strength
# only at HIGH leaves no gap between them; LOW moves the outer edge out by
# a fraction of a chunk.
EDGE_LOW, EDGE_HIGH = 0.15, 0.55


def load_regions():
    """UiMapID -> its assignment rows, as the world rectangles the art uses."""
    out = {m: [] for m in MAPS}
    for r in fetch_pinned_table("UiMapAssignment"):
        if int(r["UiMapID"]) in out:
            out[int(r["UiMapID"])].append(dict(
                map_id=int(r["MapID"]),
                top=float(r["Region_3"]), bottom=float(r["Region_0"]),
                left=float(r["Region_4"]), right=float(r["Region_1"]),
                umin=float(r["UiMin_0"]), vmin=float(r["UiMin_1"]),
                umax=float(r["UiMax_0"]), vmax=float(r["UiMax_1"])))
    return out


def tiles_needed(regions):
    """{map_id: {(row, col)}} of terrain tiles any region covers."""
    need = {}
    for rows in regions.values():
        for g in rows:
            r0, r1 = sorted((world_to_tile(g["top"]), world_to_tile(g["bottom"])))
            c0, c1 = sorted((world_to_tile(g["left"]), world_to_tile(g["right"])))
            need.setdefault(g["map_id"], set()).update(
                (r, c) for r in range(max(0, r0), min(63, r1) + 1)
                for c in range(max(0, c0), min(63, c1) + 1))
    return need


def chunk_areas(job):
    """The 16x16 AreaIDs of one terrain tile, indexed [chunk row][chunk col]."""
    map_id, row, col, fdid = job
    path = AREA_CACHE / f"{map_id}_{row}_{col}_{fdid}.bin"
    if path.exists():
        return job, np.frombuffer(path.read_bytes(), "<u2").reshape(16, 16)
    for attempt in range(4):
        try:
            adt = download_casc(fdid)
            break
        except Exception:
            if attempt == 3:
                raise
            time.sleep(2 * (attempt + 1))
    out = np.zeros((16, 16), "<u2")
    pos = 0
    while pos + 8 <= len(adt):
        magic = adt[pos:pos + 4][::-1]
        size = struct.unpack_from("<I", adt, pos + 4)[0]
        if magic == b"MCNK":
            ix, iy = struct.unpack_from("<II", adt, pos + 8 + 4)
            out[iy, ix] = struct.unpack_from("<I", adt, pos + 8 + 0x34)[0]
        pos += 8 + size
    path.write_bytes(out.tobytes())
    return job, out


def terrain_areas(need):
    """{map_id: 1024x1024 array of AreaIDs, one per chunk}, downloading as needed."""
    AREA_CACHE.mkdir(parents=True, exist_ok=True)
    jobs = []
    for map_id, tiles in need.items():
        wdt = next(WDT_CACHE_DIR.glob(f"{map_id}_*.wdt"))
        grid = parse_wdt_maid(wdt.read_bytes(), MAID_FIELD_ROOT_ADT)
        jobs += [(map_id, r, c, grid[(r, c)]) for (r, c) in sorted(tiles) if (r, c) in grid]
    print(f"  {len(jobs)} terrain tiles ...", flush=True)

    areas = {m: np.zeros((1024, 1024), "<u2") for m in need}
    with ThreadPoolExecutor(THREADS) as pool:
        for n, ((map_id, r, c, _), a) in enumerate(pool.map(chunk_areas, jobs), 1):
            areas[map_id][r * 16:(r + 1) * 16, c * 16:(c + 1) * 16] = a
            if n % 100 == 0:
                print(f"    {n}/{len(jobs)}", flush=True)
    return areas


def area_to_zone():
    """lookup[AreaID] = the zone UiMapID that area belongs to, or 0."""
    zone_maps = {int(m["ID"]) for m in fetch_pinned_table("UiMap")
                 if int(m["Type"]) == UI_MAP_TYPE_ZONE}
    owner = {int(r["AreaID"]): int(r["UiMapID"])
             for r in fetch_pinned_table("UiMapAssignment")
             if int(r["UiMapID"]) in zone_maps and int(r["AreaID"])}
    table = {int(r["ID"]): int(r["ParentAreaID"]) for r in fetch_pinned_table("AreaTable")}
    lookup = np.zeros(max(table) + 1, "<i4")
    for area in table:
        cur = area
        for _ in range(8):
            if cur in owner:
                lookup[area] = owner[cur]
                break
            cur = table.get(cur, 0)
            if not cur:
                break
    return lookup


def absorb_cities(own, real):
    """Give chunks owned by a non-zone (city) map to the nearest real zone."""
    todo = (own != 0) & ~np.isin(own, list(real))
    own[todo] = 0
    for _ in range(int(CITY_REACH_YARDS / CHUNK)):
        if not todo.any():
            break
        padded = np.pad(own, 1)  # snapshot: each round grows one chunk, evenly
        for near in (padded[:-2, 1:-1], padded[2:, 1:-1],
                     padded[1:-1, :-2], padded[1:-1, 2:]):
            take = todo & (own == 0) & (near != 0)
            own[take] = near[take]
            todo &= ~take
    return own


def pow2(n):
    return 1 << max(5, (int(np.ceil(n)) - 1).bit_length())


def zone_mask(own, zone):
    """(mask image, chunk box x0, y0, x1, y1) for one zone's chunks."""
    ys, xs = np.nonzero(own == zone)
    x0, x1 = max(0, xs.min() - PAD), min(1024, xs.max() + 1 + PAD)
    y0, y1 = max(0, ys.min() - PAD), min(1024, ys.max() + 1 + PAD)
    chunks = (own[y0:y1, x0:x1] == zone)
    big = np.kron(chunks, np.ones((SUPERSAMPLE, SUPERSAMPLE), bool)).astype("uint8") * 255
    img = Image.fromarray(big, "L").filter(
        ImageFilter.GaussianBlur(BLUR_CHUNKS * SUPERSAMPLE))
    a = np.clip((np.asarray(img, "float32") / 255 - EDGE_LOW) / (EDGE_HIGH - EDGE_LOW), 0, 1)
    size = (pow2((x1 - x0) * MIN_PX_PER_CHUNK), pow2((y1 - y0) * MIN_PX_PER_CHUNK))
    alpha = Image.fromarray((a * 255).round().astype("uint8"), "L").resize(size, Image.LANCZOS)
    rgba = Image.merge("RGBA", (*(Image.new("L", size, 255),) * 3, alpha))
    return rgba, (x0, y0, x1, y1)


def map_box(g, box):
    """A chunk box as 0-1 coordinates (u0, v0, u1, v1) on the map region g draws."""
    x0, y0, x1, y1 = box
    def u(cx):
        return g["umin"] + (g["left"] - (32 * TILE_WORLD_SIZE - cx * CHUNK)) \
            / (g["left"] - g["right"]) * (g["umax"] - g["umin"])
    def v(cy):
        return g["vmin"] + (g["top"] - (32 * TILE_WORLD_SIZE - cy * CHUNK)) \
            / (g["top"] - g["bottom"]) * (g["vmax"] - g["vmin"])
    return u(x0), v(y0), u(x1), v(y1)


def main():
    regions = load_regions()
    lookup = area_to_zone()
    owners = {m: absorb_cities(lookup[np.minimum(a, len(lookup) - 1)], set(overlay_counts()))
              for m, a in terrain_areas(tiles_needed(regions)).items()}
    real = set(overlay_counts())

    MASK_DIR.mkdir(parents=True, exist_ok=True)
    masks = {}  # (terrain map, zone) -> chunk box
    total_bytes = 0
    for map_id, own in owners.items():
        for zone in sorted(real & set(np.unique(own).tolist())):
            image, box = zone_mask(own, zone)
            blp = encode_blp2_bgra(image)
            (MASK_DIR / f"z{zone}.blp").write_bytes(blp)
            total_bytes += len(blp)
            masks[(map_id, zone)] = box
    print(f"  {len(masks)} masks, {total_bytes / 1e6:.1f} MB", flush=True)

    lines = ["-- Auto-generated by scripts/emit_zone_shapes.py - DO NOT EDIT",
             "-- Per map: { zone UiMapID, u0, v0, u1, v1 } -- where ZoneMasks\\",
             "-- z<UiMapID>.blp goes, in 0-1 map coordinates. See ZoneFog.lua.",
             "HFWMF_ZONE_SHAPES = {"]
    for ui_map in MAPS:
        lines.append(f"    [{ui_map}] = {{")
        for g in regions[ui_map]:
            for (map_id, zone), box in sorted(masks.items()):
                if map_id != g["map_id"]:
                    continue
                u0, v0, u1, v1 = map_box(g, box)
                if not (g["umin"] <= (u0 + u1) / 2 < g["umax"]
                        and g["vmin"] <= (v0 + v1) / 2 < g["vmax"]):
                    continue
                lines.append(f"        {{{zone},{u0:.6f},{v0:.6f},{u1:.6f},{v1:.6f}}},")
        lines.append("    },")
    lines.append("}")
    OUT.write_text("\n".join(lines) + "\n")
    print(f"-> {OUT} ({OUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
