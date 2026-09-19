"""Real (baked, offline) indoor WMO minimap art for micro-dungeon floors.

CaveData.lua's floors currently carry ``tiles`` cropped from the *outdoor*
minimap-texture pipeline (see ``hfwm/zone.py`` / ``hfwm/db2.py``) as a
fallback, because indoor WMO minimap art is not reachable from any live
Lua API on this build (no interior ``C_Map`` rows, no ``UiMapAssignment``
row for a WMO group). That does not mean the art is unfetchable — it is
baked offline by Blizzard's own tools exactly like the outdoor tiles are,
just addressed differently:

  * Every WMO root file (``<name>.wmo``) has an ``MOGI`` chunk: one record
    per group, each carrying that group's local-space bounding box and an
    offset into ``MOGN`` for its name.
  * Each group that has minimap art gets a baked tile at
    ``world/minimaps/wmo/dungeon/<wmoFileName>/<wmoFileName>_<group:03d>_<row:02d>_<col:02d>.blp``
    (row/col only appear past ``_00_00`` for groups big enough to need more
    than one tile). This path is not in any DB2 table — the only known way
    to resolve it to a FileDataID is the community listfile
    (https://github.com/wowdev/wow-listfile), which is why the FDIDs below
    were resolved once, offline, and are pinned here rather than re-derived
    from a 150MB CSV on every generator run.

This module turns that into the same kind of stitched art the outdoor
pipeline produces: real per-group tiles, decoded with Pillow (which reads
BLP natively) and composited by each group's own MOGI bounding box, then
re-encoded as BLP2 (via :mod:`hfwm.blp`) and bundled into the addon like
any other high-fidelity art tile — so ``CaveRenderer.lua`` needs no new
code, only a ``tiles`` entry that resolves through ``FDID_MAP`` to a
bundled file instead of a live Blizzard FDID.

Scope: Fargodeep Mine only, as the first proof. ``DUNGEONS`` below is
where a second micro-dungeon's WMO would be added once this one is
confirmed in-game.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from .blp import encode_blp2_bgra
from .constants import CACHE_ROOT, WAGO_CASC_PINNED_FMT, WORLDMAP_DIR
from .http import fetch_url

WMO_CACHE_DIR = CACHE_ROOT / "wmo"
WMO_TILE_CACHE_DIR = CACHE_ROOT / "wmo_minimap"

# Synthetic FileDataIDs for the bundled composite floor art. Chosen well
# outside any real Blizzard FDID range (current live FDIDs top out well
# under 9 digits) so they can never collide with a genuine one, and grouped
# under one block (900000000+) so a future dungeon's synthetic IDs are easy
# to tell apart from this one's.
FDID_FARGODEEP_UPPER = 900000001
FDID_FARGODEEP_LOWER = 900000002


@dataclass
class WmoGroup:
    index: int
    flags: int
    bbox: tuple[float, float, float, float, float, float]  # x1,y1,z1,x2,y2,z2
    name: str
    tile_fdid: int | None


# Fargodeep Mine's actual root WMO. Discovered by checking WMOAreaTable for
# AreaTableID 57 (Fargodeep Mine's own area, already baked into CaveData.lua
# by hfwm/microdungeon.py): WMOID=996, NameSetID=3. WMOID 996 does not belong
# to the base md_goldmine.wmo (that one's WMOID is 84, and reverse-engineering
# it first was a red herring reused by four *other* mines) — it belongs to
# the "varianta" model, md_goldmine_varianta.wmo.
FARGODEEP_WMO_FDID = 110773  # world/wmo/dungeon/md_goldmine/md_goldmine_varianta.wmo

# group index -> minimap tile FDID, resolved via the community listfile
# against world/minimaps/wmo/dungeon/md_goldmine_varianta/md_goldmine_varianta_<NNN>_00_00.blp.
# Group 0 has no listfile entry at all (it is the small unnamed antiportal/
# entrance-shaft group, flags 0x8 rather than the 0x2000 every other group
# here has) and is skipped everywhere below.
FARGODEEP_TILE_FDIDS: dict[int, int] = {
    1: 214612, 2: 214613, 3: 214614, 4: 214615, 5: 214616, 6: 214617,
    7: 214618, 8: 214619, 9: 214620, 10: 214621, 11: 214622, 12: 214623,
    13: 214624, 14: 214625, 15: 214626, 16: 214627, 17: 214628, 18: 214629,
    19: 214630, 20: 214631, 21: 214632,
}


def _iter_chunks(data: bytes):
    pos = 0
    while pos < len(data) - 8:
        magic = data[pos:pos + 4][::-1].decode("ascii", errors="replace")
        size = struct.unpack_from("<I", data, pos + 4)[0]
        yield magic, data[pos + 8:pos + 8 + size]
        pos += 8 + size


def parse_wmo_groups(wmo_root_bytes: bytes,
                      tile_fdids: dict[int, int]) -> list[WmoGroup]:
    """Parse MOHD/MOGN/MOGI out of a WMO root file's raw bytes."""
    chunks = dict(_iter_chunks(wmo_root_bytes))
    mohd = chunks["MOHD"]
    (n_groups,) = struct.unpack_from("<I", mohd, 4)
    mogn = chunks.get("MOGN", b"")

    def name_at(offset: int) -> str:
        if offset < 0:
            return ""
        end = mogn.find(b"\x00", offset)
        return mogn[offset:end].decode("ascii", errors="replace")

    mogi = chunks["MOGI"]
    rec_size = 32
    n = len(mogi) // rec_size
    assert n == n_groups, f"MOGI record count {n} != MOHD nGroups {n_groups}"

    groups = []
    for i in range(n):
        flags, x1, y1, z1, x2, y2, z2, name_off = struct.unpack_from(
            "<I6fi", mogi, i * rec_size)
        groups.append(WmoGroup(
            index=i, flags=flags, bbox=(x1, y1, z1, x2, y2, z2),
            name=name_at(name_off), tile_fdid=tile_fdids.get(i),
        ))
    return groups


def _download_cached(fdid: int, cache_dir: Path) -> bytes:
    cache_dir.mkdir(parents=True, exist_ok=True)
    path = cache_dir / f"{fdid}.blp"
    if path.exists() and path.stat().st_size > 0:
        return path.read_bytes()
    data = fetch_url(WAGO_CASC_PINNED_FMT.format(fdid=fdid), timeout=30)
    path.write_bytes(data)
    return data


def fetch_wmo_root(fdid: int) -> bytes:
    return _download_cached(fdid, WMO_CACHE_DIR)


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
    data = _download_cached(fdid, WMO_TILE_CACHE_DIR)
    tmp = WMO_TILE_CACHE_DIR / f"{fdid}.blp"
    img = Image.open(tmp).convert("RGBA")
    opaque_bbox = img.split()[-1].getbbox()
    if opaque_bbox:
        img = img.crop(opaque_bbox)
    return img


def split_floors_by_height(groups: list[WmoGroup]) -> tuple[list[int], list[int]]:
    """Split tiled groups into two floors by 1D 2-means on Z-midpoint.

    Interior WMOs carry no per-floor tag anywhere in the file — the source
    DB2 rows (WMOAreaTable) don't distinguish floors within one NameSetID
    either. The groups themselves cluster into two bands (a "mine shaft"
    cluster and a "surface level" cluster), which is what a real two-storey
    mine looks like from its geometry alone. 2-means recovers that split
    without hand-picking a threshold; the simpler "largest gap between
    consecutive Z-midpoints" was tried first and picked the wrong boundary
    here — Fargodeep's tallest single room (``mine06``, z-mid 13.5) sits far
    enough above its own cluster that the widest gap isolated it alone
    rather than falling at the real floor boundary. 2-means is not fooled by
    that because it minimises total within-cluster spread, not the gap on
    either side of one point.

    Returns (lower_indices, upper_indices).
    """
    tiled = [g for g in groups if g.tile_fdid is not None]
    zmids = [((g.bbox[2] + g.bbox[5]) / 2, g.index) for g in tiled]

    c1, c2 = min(z for z, _ in zmids), max(z for z, _ in zmids)
    lower, upper = [], []
    for _ in range(100):
        lower = [(z, i) for z, i in zmids if abs(z - c1) <= abs(z - c2)]
        upper = [(z, i) for z, i in zmids if abs(z - c1) > abs(z - c2)]
        if not lower or not upper:
            break
        new_c1 = sum(z for z, _ in lower) / len(lower)
        new_c2 = sum(z for z, _ in upper) / len(upper)
        if (new_c1, new_c2) == (c1, c2):
            break
        c1, c2 = new_c1, new_c2

    return [i for _, i in lower], [i for _, i in upper]



# Pixels-per-world-unit for indoor WMO group minimap tiles, and the
# vertical-axis convention to place them with. Neither is a fitted/guessed
# value anymore — both come from reading real, shipped code that solves
# this exact problem (stitching WMO-group minimap tiles for a dungeon,
# including classic instances like Ragefire Chasm, structurally identical
# to Fargodeep Mine):
#
#   * Cal Henderson's World of MapCraft (github.com/iamcal/World-of-MapCraft,
#     build/wmo_build.php) is a real, shipped project that built exactly
#     this kind of stitched instance map for every WoW dungeon/raid,
#     including classic ones. Its build_wmo_map() scales MOGI X/Y by a
#     hardcoded ``1.993`` (comment: "need to double chunk coords") — i.e.
#     the same ~2px/unit convention, refined to a more precise constant.
#   * Critically, extract_mogi() negates the local Y coordinate before use
#     (``0 - $box[2]``, ``0 - $box[5]``) and the group's *own tile height*
#     is then subtracted from that negated-and-scaled value to anchor the
#     group's top-left corner. Un-negated, my first attempt at this mapped
#     column<-X/row<-Y directly, which gets width/height and touching-ness
#     right (bbox aspect ratio matches tile aspect ratio either way) but
#     silently mirrors the whole floor plan north-south, since increasing
#     world Y was mapped to increasing row instead of decreasing row.
#   * Marlamin's WoWTools.MinimapCompileWMO (github.com/Marlamin/
#     WoWTools.Minimaps, Program.cs) independently confirms the ~2px/unit
#     scale (``BoundingBox.Minimum.{X,Y} * 2``) and that tiles are blitted
#     at *native* resolution with zero resampling — never resized to fit a
#     target canvas.
#   * Measuring pixel-size / bbox-extent across Fargodeep's own 21 tiles
#     gives 1.78-2.01 px/unit, clustering tightly on ~1.99 — matching
#     World of MapCraft's 1.993 almost exactly, independently.
#   * wowdev.wiki/WMO's MOGI section confirms there's no separate
#     placement/rotation record to look up at all: "Groups don't have
#     placement or orientation information, because the coordinates ...
#     are already correctly transformed relative to (0,0,0)".
#
# So: bbox is placement (no rotation/skew), scale is a fixed 1.993 (not
# fitted per-floor), and the row axis is anchored from each group's
# *maximum* Y (north edge) against the floor's global maximum Y, mirroring
# extract_mogi()'s negate-then-anchor-from-top behaviour exactly.
MINIMAP_PX_PER_UNIT = 1.993


def build_floor_image(groups_by_index: dict[int, WmoGroup],
                       group_indices: list[int],
                       tiles: dict[int, Image.Image],
                       minx: float, maxy: float,
                       canvas_w: int, canvas_h: int,
                       scale: float = MINIMAP_PX_PER_UNIT) -> Image.Image:
    """Composite one floor's groups onto a shared-scale canvas.

    Screen axis mapping: canvas column <- WMO-local X (unflipped), canvas
    row <- WMO-local Y *negated* (north/max-Y renders at the top, i.e. row
    0). See MINIMAP_PX_PER_UNIT's docstring: World of MapCraft's real,
    shipped extract_mogi()/build_wmo_map() negates Y before placing tiles;
    without that flip, width/height and touching-ness both look right
    (aspect ratios match, gaps are zero) but the whole floor plan comes out
    mirrored north-south. Column still anchors off each group's own
    *minimum* X against the floor's global minimum X; row anchors off each
    group's own *maximum* Y (its north edge) against the floor's global
    maximum Y — the mirrored equivalent of the X anchor, per extract_mogi.

    Each tile is pasted at its *native* pixel resolution — no per-tile
    resize. Blizzard's own compiler and World of MapCraft both draw a
    group's tile 1:1 at the fixed scale and size the canvas around that,
    never the other way around; resizing tiles to fit an arbitrarily-chosen
    canvas size was this script's original, wrong approach.
    """
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 255))
    for idx in group_indices:
        g = groups_by_index[idx]
        x1, _, _, _, y2, _ = g.bbox
        tile = tiles[idx]
        px = round((x1 - minx) * scale)
        py = round((maxy - y2) * scale)
        canvas.alpha_composite(tile, (px, py))
    return canvas


def generate_fargodeep(scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Fetch, parse, composite and encode Fargodeep Mine's two floors.

    ``scale`` is Blizzard's own fixed minimap-baking scale (px/world-unit),
    not a target size to fit — see MINIMAP_PX_PER_UNIT. The canvas is
    *derived* from it (span * scale), never chosen first and fitted to.

    Writes ``WorldMap/FargodeepMine/{upper,lower}.blp`` and returns the Lua
    fragment values (layerW/layerH/tileW/tileH/cols/rows/tiles, and the
    synthetic FDID -> relative-path pairs for FDIDMap.lua) needed to wire
    them into CaveData.lua and FDIDMap.lua.
    """
    root_bytes = fetch_wmo_root(FARGODEEP_WMO_FDID)
    groups = parse_wmo_groups(root_bytes, FARGODEEP_TILE_FDIDS)
    by_index = {g.index: g for g in groups}

    lower_idx, upper_idx = split_floors_by_height(groups)

    tiled_idx = [g.index for g in groups if g.tile_fdid is not None]
    tiles = {i: fetch_tile(by_index[i].tile_fdid) for i in tiled_idx}

    xs = [by_index[i].bbox[0] for i in tiled_idx] + \
         [by_index[i].bbox[3] for i in tiled_idx]
    ys = [by_index[i].bbox[1] for i in tiled_idx] + \
         [by_index[i].bbox[4] for i in tiled_idx]
    minx, maxy = min(xs), max(ys)
    # Canvas size is derived from where each tile's native-resolution
    # rectangle actually lands (px0..px0+tile.width, py0..py0+tile.height),
    # not from bbox span * scale — a tile's native size only approximates
    # bbox_extent * scale to the nearest bake-time pixel (see
    # MINIMAP_PX_PER_UNIT), so sizing the canvas off the bbox span alone
    # can clip a tile that runs slightly larger than its own bbox implies.
    canvas_w = max(round((by_index[i].bbox[0] - minx) * scale) + tiles[i].width
                   for i in tiled_idx)
    canvas_h = max(round((maxy - by_index[i].bbox[4]) * scale) + tiles[i].height
                   for i in tiled_idx)

    out_dir = WORLDMAP_DIR / "FargodeepMine"
    out_dir.mkdir(parents=True, exist_ok=True)

    upper_img = build_floor_image(
        by_index, upper_idx, tiles, minx, maxy, canvas_w, canvas_h, scale)
    lower_img = build_floor_image(
        by_index, lower_idx, tiles, minx, maxy, canvas_w, canvas_h, scale)

    (out_dir / "upper.blp").write_bytes(encode_blp2_bgra(upper_img))
    (out_dir / "lower.blp").write_bytes(encode_blp2_bgra(lower_img))

    common = dict(layerW=canvas_w, layerH=canvas_h,
                  tileW=canvas_w, tileH=canvas_h, cols=1, rows=1)
    return {
        "upper": {**common, "tiles": [FDID_FARGODEEP_UPPER],
                  "groups": sorted(upper_idx),
                  "names": [by_index[i].name for i in sorted(upper_idx)]},
        "lower": {**common, "tiles": [FDID_FARGODEEP_LOWER],
                  "groups": sorted(lower_idx),
                  "names": [by_index[i].name for i in sorted(lower_idx)]},
        "fdid_map_entries": {
            FDID_FARGODEEP_UPPER: "FargodeepMine\\upper",
            FDID_FARGODEEP_LOWER: "FargodeepMine\\lower",
        },
        "canvas": (canvas_w, canvas_h),
    }


if __name__ == "__main__":
    result = generate_fargodeep()
    print("canvas:", result["canvas"])
    for floor in ("upper", "lower"):
        f = result[floor]
        print(f"\n-- {floor} --")
        print(f"  groups: {f['groups']}")
        print(f"  names:  {f['names']}")
        print(f"  layerW = {f['layerW']}, layerH = {f['layerH']},")
        print(f"  tileW  = {f['tileW']}, tileH  = {f['tileH']},")
        print(f"  cols   = {f['cols']}, rows   = {f['rows']},")
        print(f"  tiles  = {{ {f['tiles'][0]} }},")
    print("\n-- FDIDMap.lua entries --")
    for fdid, rel in result["fdid_map_entries"].items():
        print(f'    [{fdid}] = "{rel}",')
