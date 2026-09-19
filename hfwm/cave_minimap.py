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

# Fargodeep's WMO *instance* — how the world actually places that root file
# into Dun Morogh, needed only for the world-alignment rotation (see
# WORLD_YAW_FOR_CANVAS_ROTATION below). Found the same way the WMO/tile
# FDIDs above were: no DB2 table carries this, so it comes from the actual
# ADT that covers Fargodeep Mine's own world-space bounds (CaveData.lua's
# existing ``bounds = { -9860, -9700, 41.75, 281.75 }``, run through
# hfwm/coordinates.py's world_to_tile on both axes -> ADT tile (31, 50) on
# Map 0 "Azeroth" -> looked up in the wowdev/wow-listfile release CSV as
# ``world/maps/azeroth/azeroth_31_50_obj0.adt``, FileDataID 777838; the
# root ``..._31_50.adt`` (777837) carries no MWMO/MODF/MDDF at all — they
# live entirely in ``_obj0`` on this build, and MODF's ``nameId`` there is
# already a raw FileDataID (flags & 0x8, no MWID indirection) since neither
# an MWID nor MWMO chunk exists to index into.
FARGODEEP_ADT_OBJ0_FDID = 777838  # world/maps/azeroth/azeroth_31_50_obj0.adt

# The specific MODF record for Fargodeep, for a same-file sanity check
# rather than blind trust in "the one entry whose nameId matches": its
# nameSet (3) matches the WMOAreaTable NameSetID already used elsewhere in
# this project to identify Fargodeep's WMO (see FARGODEEP_WMO_FDID above),
# so both independent lookups (AreaTable's WMOAreaTable row, and this
# ADT's own MODF entry) agree on the same placement.
FARGODEEP_MODF_UNIQUE_ID = 210351
FARGODEEP_MODF_NAME_SET = 3

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


@dataclass
class WmoPlacement:
    unique_id: int
    position: tuple[float, float, float]
    rotation: tuple[float, float, float]  # degrees: (pitch, yaw, roll)
    name_set: int


def parse_modf_placements(obj0_adt_bytes: bytes,
                           wmo_fdid: int) -> list[WmoPlacement]:
    """Parse every MODF record in a split-format ``_obj0.adt`` that places
    *wmo_fdid*, direct-FileDataID mode only.

    ``SMMapObjDef`` (wowdev.wiki/ADT/v18#MODF_chunk) is 64 bytes: nameId,
    uniqueId, C3Vector position, C3Vector rotation, CAaBox extents,
    flags, doodadSet, nameSet, scale. This build's Fargodeep-covering ADT
    carries no MWMO/MWID chunk at all (confirmed by scanning its own
    top-level chunk list), which only makes sense if ``modf_entry_is_
    filedata_id`` (flag 0x8) is set on every record and ``nameId`` is
    already the FileDataID — so that's the only mode this parses; a
    record without that flag would need an MWID lookup this function
    doesn't have and is skipped rather than misread.
    """
    pos = 0
    placements: list[WmoPlacement] = []
    while pos < len(obj0_adt_bytes) - 8:
        magic = obj0_adt_bytes[pos:pos + 4][::-1]
        size = struct.unpack_from("<I", obj0_adt_bytes, pos + 4)[0]
        if magic == b"MODF":
            body = obj0_adt_bytes[pos + 8:pos + 8 + size]
            for i in range(len(body) // 64):
                (name_id, unique_id, px, py, pz, rx, ry, rz,
                 *_rest_bbox, flags, doodad_set, name_set, _scale) = \
                    struct.unpack_from("<II3f3f6fHHHH", body, i * 64)
                if name_id != wmo_fdid or not (flags & 0x8):
                    continue
                placements.append(WmoPlacement(
                    unique_id=unique_id, position=(px, py, pz),
                    rotation=(rx, ry, rz), name_set=name_set,
                ))
        pos += 8 + size
    return placements


def fetch_wmo_world_yaw(adt_obj0_fdid: int, wmo_fdid: int,
                         expected_unique_id: int | None = None) -> float:
    """Return the WMO instance's placement yaw (MODF rotation.y, degrees).

    Pitch/roll (rotation.x / rotation.z) are not returned: this project
    only ever composites a *flat*, top-down floor plan, and wowdev.wiki's
    ADT/v18 coordinate-system table names rotation.y specifically as "the
    rotation around the Up axis" — the only component that can matter for
    a top-down image. A cave placed with real pitch/roll would need actual
    3-D re-projection this pipeline doesn't (yet) do; Fargodeep's own
    record has rotation == (0.0, 301.5, 0.0), i.e. flat, so this isn't
    exercised here.
    """
    data = _download_cached(adt_obj0_fdid, WMO_CACHE_DIR)
    placements = parse_modf_placements(data, wmo_fdid)
    if expected_unique_id is not None:
        placements = [p for p in placements if p.unique_id == expected_unique_id]
    if not placements:
        raise ValueError(
            f"No MODF placement of WMO {wmo_fdid} found in ADT {adt_obj0_fdid}"
            + (f" with uniqueId {expected_unique_id}" if expected_unique_id else ""))
    return placements[0].rotation[1]


def fetch_wmo_world_placement(adt_obj0_fdid: int, wmo_fdid: int,
                               expected_unique_id: int | None = None) -> WmoPlacement:
    """Return the full MODF placement record (position + rotation), for
    callers that need more than just the yaw — see
    ``world_z_range_for_groups`` for why the height component matters here.
    """
    data = _download_cached(adt_obj0_fdid, WMO_CACHE_DIR)
    placements = parse_modf_placements(data, wmo_fdid)
    if expected_unique_id is not None:
        placements = [p for p in placements if p.unique_id == expected_unique_id]
    if not placements:
        raise ValueError(
            f"No MODF placement of WMO {wmo_fdid} found in ADT {adt_obj0_fdid}"
            + (f" with uniqueId {expected_unique_id}" if expected_unique_id else ""))
    return placements[0]


def world_z_range_for_groups(groups_by_index: dict[int, "WmoGroup"],
                              group_indices: list[int],
                              placement: WmoPlacement) -> tuple[float, float]:
    """Real world-space (worldZ) height range spanned by a floor's groups.

    ``CaveTable.lua``'s ``Contains()`` can't tell Fargodeep's two floors
    apart from X/Y alone over most of the mine — the DB2 rows behind
    ``CaveData.lua``'s ``bounds`` carry no usable Z at all (every interior
    row reads -10000/1000000), and the two floors' real footprints overlap
    almost entirely in a vertical shaft. This WMO's own group geometry
    (already fetched for the art itself) has the real Z data that's
    missing, so it's reused here rather than guessed.

    Converting a group's *local* bbox Z into *world* Z needs the
    placement's own height offset — and that offset is the MODF record's
    raw **y** field, not its z field, per wowdev.wiki/ADT/v18's coordinate
    table: the WDT/ADT (Terrain) axes are `Forward*x + Left*y + Up*z`-style
    Vector3s built from the *placement* row's fields as
    ``Left*x' + Up*y + Forward*z'`` (``x' = 32*TILESIZE - x``,
    ``z' = 32*TILESIZE - z``) — i.e. the raw ``y`` field is Up (height)
    unmodified, while the raw ``x``/``z`` fields are the two *horizontal*
    terrain axes, each needing the ``32*TILESIZE - value`` correction.

    This isn't a guess: it's cross-checked against data this project
    already trusts. Applying that same transform to Fargodeep's own MODF
    position — x'=17066.67-16873.15=193.52, z'=17066.67-26900.29=-9833.62
    (TILESIZE=533.333) — lands *inside* ``CaveData.lua``'s existing
    ``bounds = {-9880, -9700, 34.25, 289.25}`` for this exact place, a
    rectangle that was itself independently confirmed correct from two
    live ``/hfwm debug`` captures (see ``CaveTable.lua``'s ``Contains()``
    comment). Both raw x and raw z land in-range; the raw y field is what's
    left over for height, matching the "Up" row of the same table.

    Yaw (rotation about Up) never changes height, so no rotation math is
    needed here — just the additive offset.

    Returns ``(worldZMin, worldZMax)`` across the given groups.
    """
    local_zs = []
    for i in group_indices:
        g = groups_by_index[i]
        local_zs.append(g.bbox[2])
        local_zs.append(g.bbox[5])
    height_offset = placement.position[1]
    return (min(local_zs) + height_offset, max(local_zs) + height_offset)


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


def world_align_rotation_degrees(placement_yaw_degrees: float) -> float:
    """PIL ``Image.rotate()`` angle (CCW-positive) that turns a
    ``build_floor_image()`` canvas from WMO-group-local orientation into
    world/true-north-up orientation, given the WMO instance's MODF
    ``rotation.y`` (degrees).

    Why this is needed at all: ``build_floor_image()`` places tiles using
    each group's own MOGI bounding box, which is in the *WMO's own local
    model space* — correct for every fix so far, because Marlamin's
    compiler and World of MapCraft both build that same local-space image
    and stop there. But those two tools are solving a different problem
    than this one: they bake either a standalone WMO asset (no placement
    at all) or a *dungeon-only* WDT's instance WMO (placed at a fixed,
    always-zero rotation by convention, since an instance has no outdoor
    terrain to be misaligned with). Fargodeep Mine is a real open-world
    micro-dungeon: its WMO is placed into Dun Morogh's terrain with a
    real, non-zero MODF rotation (301.5 degrees — see
    ``fetch_wmo_world_yaw``), and unlike the small minimap widget (which
    rotates freely with the player's facing, so a WMO-local-space image is
    fine there), the World Map this addon draws over is always north-up.
    Composited-but-unrotated, Fargodeep's floor plan is turned exactly as
    far from north-up as its placement is turned from identity — which is
    what the user is seeing when they say the cave's orientation is wrong.

    Derivation (no shipped tool does this step, so this one is worked from
    wowdev.wiki/ADT/v18's own coordinate-system table rather than fitted):

      * "M2/WMO (Models)" axes: local +X = South, local +Y = East. MOGI
        bounding boxes are in this space, so a group's local (x, y) is
        world-relative (South, East) = (x, y) *before* placement rotation.
      * "MDDF/MODF (Placement)" row: "Rotation y: around Up axis" — i.e.
        ``rotation.y`` is precisely the yaw applied about the vertical
        axis when placing the model into the world, in a right-handed
        sense (the same table's "for LH renderers, all rotations have to
        be negated" note is a caveat for the *other* case, not this one).
        A right-handed yaw about Up rotates East *towards* North for
        positive angle (Up = East x North).
      * ``build_floor_image`` already maps canvas column <- local X,
        canvas row <- -(local Y) (see its own docstring). Composing that
        fixed mapping with the placement rotation and solving for the
        pure-2D transform from (column, row) to a north-up map (column <-
        world East, row <- -world North) collapses to a single rotation:
        world-up-map angle = 90 - rotation.y, applied *clockwise* to the
        pixel grid (a rotation matrix applied directly to row-down pixel
        coordinates is clockwise for a positive angle, not counter-
        clockwise, because the row axis is flipped relative to the
        right-handed math the matrix assumes).
      * ``Image.rotate()`` is counter-clockwise-positive, so negate:
        PIL angle = rotation.y - 90.

    This is the one step in the whole pipeline that isn't cross-checked
    against a second independent shipped implementation the way the
    placement/scale fix was (nothing else stitches an open-world WMO cave
    onto a north-up world map), so it should be treated as the first
    thing to double check in-game: if the cave's orientation still looks
    wrong, flipping the sign here (``90 - rotation.y`` instead of
    ``rotation.y - 90``) is the first thing to try.
    """
    return placement_yaw_degrees - 90.0


def world_to_local_projection(placement: WmoPlacement,
                               min_local_x: float, max_local_y: float,
                               scale: float,
                               pre_rotate_w: int, pre_rotate_h: int,
                               rotate_angle_degrees: float,
                               rotated_w: int, rotated_h: int) -> dict:
    """The constants ``CaveTable:GetPlayerPosition`` needs to place the
    player pin on Fargodeep's rotated, WMO-local-coordinate art, baked once
    here rather than re-derived in Lua at runtime.

    Two transforms chain together, both already exercised elsewhere in this
    file and cross-checked against data this project independently trusts
    (the same standard used for ``world_z_range_for_groups``'s height fix):

    1. World -> WMO-local (X, Y). This is ``world_z_range_for_groups``'s
       horizontal-plane counterpart: that function converts local Z to
       world Z with a pure offset (yaw never changes height); this is the
       remaining rotation for the horizontal plane. Forward direction
       (local -> world), combining the M2/WMO local-axis convention (local
       +X = South, local +Y = East) with a right-handed yaw about Up
       (``world_align_rotation_degrees``'s "East towards North" fact) and
       the MODF raw-field convention already validated for height:

           northOffset = -localX * cos(yaw) + localY * sin(yaw)
           eastOffset  =  localX * sin(yaw) + localY * cos(yaw)
           worldX = placementWorldX + northOffset   -- north component
           worldY = placementWorldY - eastOffset     -- west component

       where ``placementWorldX = 32*TILESIZE - placement.position.z`` and
       ``placementWorldY = 32*TILESIZE - placement.position.x`` (the same
       raw-x/raw-z -> world horizontal-axis correction already validated in
       ``world_z_range_for_groups``'s docstring). The 2x2 matrix this
       represents is its own inverse (determinant -1, and squares to
       identity), so the world -> local direction baked here reuses the
       same cos/sin terms:

           localX = -northOffset * cos(yaw) + eastOffset * sin(yaw)
           localY =  northOffset * sin(yaw) + eastOffset * cos(yaw)

       Validated in this session two ways: (a) transforming every one of
       Fargodeep's 21 WMO groups' bbox corners through the forward
       transform lands their world-space bounding box at
       X in [-9870.7, -9711.2], Y in [63.9, 215.9] — inside
       CaveData.lua's already-trusted place ``bounds`` of
       {-9880, -9700, 34.25, 289.25} in both axes, exactly as expected
       for a WMO's own geometric footprint sitting inside the DB2 area's
       (necessarily coarser) bounding rectangle; (b) a local -> world ->
       local round trip over the same 21 corners is exact (0.000000 unit
       error), confirming the inverse is algebraically correct, not just
       plausible.

    2. WMO-local (X, Y) -> baked pixel. This is exactly
       ``build_floor_image``'s own per-group placement formula
       (``px = (x - minLocalX) * scale``, ``py = (maxLocalY - y) * scale``)
       generalised from a group anchor to any point, followed by the same
       ``Image.rotate(angle, expand=True)`` pixel transform already
       empirically validated against Pillow's real behaviour elsewhere in
       this project (rotate about the pre-rotation image's own center,
       re-center in the larger post-rotation canvas). Re-validated here at
       Fargodeep's actual dimensions (348x257 -> 432x401 at 211.5 degrees)
       against real marked-pixel round trips through Pillow, matching to
       within ~1px (antialiasing) on every test point.

    Both floors share every value here — same WMO instance, same
    placement, same shared pre-rotation canvas — so this is computed once
    and stored at the *place* level in CaveData.lua, not per floor.
    """
    px, py, pz = placement.position
    yaw = placement.rotation[1]
    tilesize = 533.33333
    placement_world_x = 32 * tilesize - pz
    placement_world_y = 32 * tilesize - px
    return {
        "minLocalX": min_local_x,
        "maxLocalY": max_local_y,
        "scale": scale,
        "preRotW": pre_rotate_w,
        "preRotH": pre_rotate_h,
        "rotateAngle": rotate_angle_degrees,
        "rotatedW": rotated_w,
        "rotatedH": rotated_h,
        "yaw": yaw,
        "placementWorldX": placement_world_x,
        "placementWorldY": placement_world_y,
    }


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
    # Pre-rotation canvas size, kept for the projection block below — both
    # floors share this exact (canvas_w, canvas_h) at this point in the
    # function, before either gets rotated/padded.
    pre_rotate_w, pre_rotate_h = canvas_w, canvas_h

    out_dir = WORLDMAP_DIR / "FargodeepMine"
    out_dir.mkdir(parents=True, exist_ok=True)

    upper_img = build_floor_image(
        by_index, upper_idx, tiles, minx, maxy, canvas_w, canvas_h, scale)
    lower_img = build_floor_image(
        by_index, lower_idx, tiles, minx, maxy, canvas_w, canvas_h, scale)

    # Rotate both floors into world/true-north-up orientation. Same yaw
    # for both: they're two floors of one WMO instance, placed as a unit
    # (see world_align_rotation_degrees's docstring for why this step
    # exists and where the angle comes from).
    placement = fetch_wmo_world_placement(
        FARGODEEP_ADT_OBJ0_FDID, FARGODEEP_WMO_FDID, FARGODEEP_MODF_UNIQUE_ID)
    placement_yaw = placement.rotation[1]
    rotate_angle = world_align_rotation_degrees(placement_yaw)

    # Real per-floor worldZ ranges for CaveTable.lua's floor-selection tie
    # break — see world_z_range_for_groups's docstring for why the DB2-baked
    # bounds can't provide this themselves.
    lower_z_range = world_z_range_for_groups(by_index, lower_idx, placement)
    upper_z_range = world_z_range_for_groups(by_index, upper_idx, placement)
    upper_img = upper_img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 255))
    lower_img = lower_img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 255))
    # expand=True can size the two floors' canvases slightly differently
    # (rotating a WxH box by a non-multiple-of-90 angle rounds bounding
    # dimensions independently) even though they were built on one shared
    # WxH canvas beforehand; pad both to the union so layerW/layerH stays
    # single-valued, same as CaveData.lua expects one size per place.
    out_w = max(upper_img.width, lower_img.width)
    out_h = max(upper_img.height, lower_img.height)
    if upper_img.size != (out_w, out_h):
        padded = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 255))
        padded.paste(upper_img, (0, 0))
        upper_img = padded
    if lower_img.size != (out_w, out_h):
        padded = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 255))
        padded.paste(lower_img, (0, 0))
        lower_img = padded
    canvas_w, canvas_h = out_w, out_h

    (out_dir / "upper.blp").write_bytes(encode_blp2_bgra(upper_img))
    (out_dir / "lower.blp").write_bytes(encode_blp2_bgra(lower_img))

    # World<->pixel projection for CaveTable.lua's GetPlayerPosition — see
    # world_align_rotation_degrees's docstring for the rotation half of this
    # and world_to_local_projection() below for the placement half. Both
    # floors share every one of these values (same WMO instance, same
    # composite pipeline, same shared pre-rotation canvas), so this is one
    # block at the *place* level, not duplicated per floor.
    projection = world_to_local_projection(
        placement, minx, maxy, scale, pre_rotate_w, pre_rotate_h,
        rotate_angle, canvas_w, canvas_h)

    common = dict(layerW=canvas_w, layerH=canvas_h,
                  tileW=canvas_w, tileH=canvas_h, cols=1, rows=1)
    return {
        "upper": {**common, "tiles": [FDID_FARGODEEP_UPPER],
                  "groups": sorted(upper_idx),
                  "names": [by_index[i].name for i in sorted(upper_idx)],
                  "zMin": upper_z_range[0], "zMax": upper_z_range[1]},
        "lower": {**common, "tiles": [FDID_FARGODEEP_LOWER],
                  "groups": sorted(lower_idx),
                  "names": [by_index[i].name for i in sorted(lower_idx)],
                  "zMin": lower_z_range[0], "zMax": lower_z_range[1]},
        "fdid_map_entries": {
            FDID_FARGODEEP_UPPER: "FargodeepMine\\upper",
            FDID_FARGODEEP_LOWER: "FargodeepMine\\lower",
        },
        "canvas": (canvas_w, canvas_h),
        "projection": projection,
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
        print(f"  zMin   = {f['zMin']:.2f}, zMax   = {f['zMax']:.2f},")
    print("\n-- FDIDMap.lua entries --")
    for fdid, rel in result["fdid_map_entries"].items():
        print(f'    [{fdid}] = "{rel}",')
    p = result["projection"]
    print("\n-- projection (place-level) --")
    print(f"  minLocalX = {p['minLocalX']:.6f}, maxLocalY = {p['maxLocalY']:.6f},")
    print(f"  scale = {p['scale']},")
    print(f"  preRotW = {p['preRotW']}, preRotH = {p['preRotH']},")
    print(f"  rotateAngle = {p['rotateAngle']},")
    print(f"  rotatedW = {p['rotatedW']}, rotatedH = {p['rotatedH']},")
    print(f"  yaw = {p['yaw']},")
    print(f"  placementWorldX = {p['placementWorldX']:.6f}, placementWorldY = {p['placementWorldY']:.6f},")
