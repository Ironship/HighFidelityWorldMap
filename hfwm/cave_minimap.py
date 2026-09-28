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

Scope: every parsing/compositing primitive below (``parse_wmo_groups``,
``parse_modf_placements``, ``build_floor_image``, ``world_to_local_
projection``, etc.) is generic — none of it reads a Fargodeep-specific
value directly. What *is* still per-mine is a small handful of raw
FileDataIDs (which WMO, which ADT, which minimap tiles) that identify
Fargodeep's own placement in the world; those are collected into a
``MineSpec`` below. ``MINES`` is the registry a second micro-dungeon
gets added to once its own IDs are known — see ``ECHO_RIDGE`` for a
stub showing exactly which values are still missing and how to find
them.
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

# Per-piece synthetic FDIDs (Phase 2: continuous per-WMO-group fading rather
# than a 2-floor crossfade). Base chosen with a gap after the two floor IDs
# above so the ranges are visually distinct in FDIDMap.lua; one ID is
# consumed per tiled WMO group, in ascending group-index order, and
# Fargodeep has 21 tiled groups (see FARGODEEP_TILE_FDIDS below) so this
# range only needs to reserve 900000010-900000030 — comfortably short of
# colliding with FDID_FARGODEEP_UPPER/LOWER's block or a next dungeon's.
FDID_FARGODEEP_PIECE_BASE = 900000010


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


@dataclass
class MineSpec:
    """Everything ``generate_mine_floors``/``generate_mine_pieces`` need to
    bake one micro-dungeon's satellite-view art.

    This is the parameterisation of what used to be five Fargodeep-only
    module globals (``FARGODEEP_WMO_FDID`` and friends, still above —
    ``FARGODEEP`` below just wraps them). Adding a second mine means
    filling in one more of these, not writing new baking code.
    """
    key: str                     # WorldMap/<key>/ output folder, e.g. "FargodeepMine"
    wmo_fdid: int | None         # root WMO file (world/wmo/dungeon/.../x.wmo)
    tile_fdids: dict[int, int]   # WMO group index -> its minimap tile FDID
    adt_obj0_fdid: int | None    # the _obj0.adt that places wmo_fdid in the world
    modf_unique_id: int | None   # MODF uniqueId, in case more than one MODF
                                  # record in that ADT places this same wmo_fdid
    modf_name_set: int | None    # cross-check against WMOAreaTable's NameSetID
    floor_fdid_base: int         # synthetic FDID(s) for the whole-floor composite(s)
    piece_fdid_base: int         # synthetic FDID base for the per-room pieces
    single_floor: bool = False   # True: one floor, no crossfade/sharedCanvas


# Fargodeep Mine — fully populated, in production (see CaveData.lua's
# "Fargodeep Mine" entry). Wraps the constants above rather than
# retyping them, so there is exactly one place each number lives.
FARGODEEP = MineSpec(
    key="FargodeepMine",
    wmo_fdid=FARGODEEP_WMO_FDID,
    tile_fdids=FARGODEEP_TILE_FDIDS,
    adt_obj0_fdid=FARGODEEP_ADT_OBJ0_FDID,
    modf_unique_id=FARGODEEP_MODF_UNIQUE_ID,
    modf_name_set=FARGODEEP_MODF_NAME_SET,
    floor_fdid_base=FDID_FARGODEEP_UPPER,  # consumes this id and the next (lower)
    piece_fdid_base=FDID_FARGODEEP_PIECE_BASE,
    single_floor=False,
)

# Echo Ridge Mine — progress so far (from a live WMOAreaTable.csv export,
# build 1.60.1.69913): AreaTableID 34 rows give WMOID=84, NameSetID=3.
# WMOID 84 is the *base* md_goldmine.wmo (not the "_varianta" model
# Fargodeep uses, WMOID 996 -- see FARGODEEP_WMO_FDID's comment) -- the
# same base model already noted there as being reused by several other
# mines. NameSetID 3 matches Fargodeep's own placement, consistent with
# both being the same WMO family. Still needed: the base model's own
# FileDataID (not 110773 -- that's the varianta model), its per-group
# minimap tile FDIDs, and the ADT placing it (candidate ADT tile (32, 48)
# on Map 0 "Azeroth", from running CaveData.lua's bounds {-8686, -8500,
# -306, -27} through world_to_tile on both axes -- (32, 47) as a fallback
# since the Y span straddles that tile's boundary).
#
# AreaTable 34, uiMapID 426 (CaveData.lua already has a
# generic single-floor entry for it, baked by hfwm/microdungeon.py from
# this build's own real MicroDungeon world-map art). It has only one
# floor, so single_floor=True: there is no crossfade/sharedCanvas question
# for it, only the per-room `pieces` treatment Fargodeep's Phase 2 added.
#
# The five fields below are None/empty because — unlike everything else in
# this file — they cannot be pulled from any table this project already
# fetches. They have to be looked up once, by hand, exactly the way
# Fargodeep's were (see FARGODEEP_WMO_FDID's comment above for the worked
# example); each step below is that same recipe applied to this mine:
#
#   1. wmo_fdid       - wago.tools -> DB2 -> WMOAreaTable, filtered to
#                        AreaTableID 34. Note the WMOID/NameSetID columns,
#                        then resolve that WMOID to an actual root .wmo
#                        FileDataID via wago.tools' file browser or the
#                        wow-listfile (github.com/wowdev/wow-listfile) —
#                        Fargodeep's WMOID (996) turned out to be
#                        md_goldmine_varianta.wmo, FDID 110773; expect a
#                        similarly-named dungeon wmo here, not necessarily
#                        the same file or even the same base model.
#   2. adt_obj0_fdid  - CaveData.lua's existing bounds for this place
#                        ({-8686, -8500, -306, -27}) run through
#                        hfwm/coordinates.py's world_to_tile on both axes
#                        to get the covering ADT's column/row, then the
#                        matching world/maps/<continent>/<continent>_
#                        <col>_<row>_obj0.adt resolved to a FileDataID
#                        the same way FARGODEEP_ADT_OBJ0_FDID was.
#   3. modf_unique_id
#   4. modf_name_set  - fetch that _obj0.adt and run parse_modf_placements()
#                        (this file) against wmo_fdid from step 1 to find
#                        the matching record; its uniqueId and nameSet are
#                        these two fields. nameSet should match
#                        WMOAreaTable's NameSetID from step 1 — if it
#                        doesn't, it's the wrong placement.
#   5. tile_fdids     - once wmo_fdid's own path is known, call
#                        fetch_wmo_root + parse_wmo_groups() (this file) to
#                        enumerate its MOGI groups, then resolve each
#                        tiled group's minimap tile FDID the same way
#                        FARGODEEP_TILE_FDIDS was: world/minimaps/wmo/
#                        dungeon/<wmoName>/<wmoName>_<group:03d>_00_00.blp
#                        against the listfile.
#
# None of this is guessable from inside this repo, and none of it should
# be trusted un-checked once filled in: Fargodeep's rotation math
# (world_align_rotation_degrees) is cross-validated against Fargodeep's
# own live /hfwm debug captures specifically, not against this mine's —
# so treat a first attempt here as provisional until the same in-game
# check confirms the cave's orientation and player-pin position look
# right. Once the five fields above are filled in, run
# ``python -m hfwm.cave_minimap echoridge`` and paste its output into
# CaveData.lua / FDIDMap.lua the same way Fargodeep's was.
#
# Update (from a live community-listfile.csv, same build): wmo_fdid and
# tile_fdids resolved cleanly — "world/wmo/dungeon/md_goldmine/md_goldmine
# .wmo" (the bare name, WMOID 84, matching WMOAreaTable) is FDID 110750,
# and its own minimap tiles are the *only* "md_goldmine_NNN_00_00.blp"
# entries with no variant suffix: groups 000-008, FDIDs 214595-214603,
# nine in a row with no gap. That strongly implies 9 tiled groups
# numbered from 0 (unlike Fargodeep's varianta, which skips an untiled
# group 0 and numbers tiles from 1) — but this is only a hypothesis from
# the listfile; the real group count/order still needs confirming
# against the WMO file's own MOHD/MOGI chunks once fetched, same as
# everything parse_wmo_groups() checks for Fargodeep.
#
# Fully resolved (from the actual WMO + both candidate ADTs, fetched from
# cache and parsed with this file's own parse_wmo_groups/parse_modf_
# placements): the WMO really does have 10 groups, exactly 9 of them
# (0-8, flags 0x2000) tiled -- matching FDIDs 214595-214603 one-for-one,
# confirming the tile_fdids guessed from the listfile above needed no
# changes. Group 9 (flags 0x8, "interior02") is the untiled antiportal/
# entrance group, the same role Fargodeep's untiled group plays.
#
# Both candidate ADTs (778023 and 778028) carry the *same* MODF record
# for this WMO -- uniqueId 71448, pos (17198.39, 91.62, 25712.89), yaw
# 325.0, nameSet 3 (matching WMOAreaTable exactly) -- because the
# placement really does straddle the tile (32,47)/(32,48) seam, as
# guessed from the bounds earlier. Either FDID works identically;
# 778028 is kept as primary. Running this position through the same
# raw-x/z -> world correction Fargodeep's derivation validates
# (placementWorldX = 32*TILESIZE - pz, placementWorldY = 32*TILESIZE -
# px) lands at (-8646.22, -131.72) -- inside CaveData.lua's existing
# bounds {-8686, -8500, -306, -27} on both axes, the same cross-check
# Fargodeep's own placement was validated with.
ECHO_RIDGE = MineSpec(
    key="EchoRidgeMine",
    wmo_fdid=110750,
    tile_fdids={i: 214595 + i for i in range(9)},
    adt_obj0_fdid=778028,
    modf_unique_id=71448,
    modf_name_set=3,
    floor_fdid_base=900000100,   # first free block after Fargodeep's piece range
    piece_fdid_base=900000200,   # (900000010-900000030) and floor range (...01-02)
    single_floor=True,
)


# --- Batch 3: 13 more micro-dungeons resolved from ADT MODF placement data
# directly (see the 2026-09-28 session) rather than name-guessing --
# WMOAreaTable + community-listfile.csv + each covering ADT's own MODF
# chunk gave every raw ID with no ambiguity. All single_floor=True (no
# retail-floor-count-driven 2-means split attempted); every group used
# below is single-subtile (_00_00 only) -- mines needing multi-subtile
# group art are held back for a later pass.
BANETHILBARROWDEN = MineSpec(
    key='BanethilBarrowDen',
    wmo_fdid=110359,
    tile_fdids={0: 214278, 1: 214279, 2: 214280, 3: 214281, 4: 214282, 5: 214283, 6: 214284, 7: 214285, 8: 214286, 9: 214287, 10: 214288, 11: 214289, 12: 214290, 13: 214291, 14: 214292, 15: 214293, 16: 214294, 17: 214295, 18: 214296, 19: 214297, 20: 214298, 21: 214299, 22: 214300, 23: 214301, 24: 214302, 25: 214303, 27: 214304, 28: 214305, 29: 214306, 30: 214307, 31: 214308, 32: 214309},
    adt_obj0_fdid=783826,
    modf_unique_id=173805,
    modf_name_set=3,
    floor_fdid_base=900000300,
    piece_fdid_base=900000400,
    single_floor=True,
)

COLDRIDGEPASS = MineSpec(
    key='ColdridgePass',
    wmo_fdid=110345,
    tile_fdids={0: 214267, 1: 214268, 2: 214269, 3: 214270, 4: 214271, 5: 214272, 6: 214273, 7: 214274, 8: 214275, 10: 214276, 12: 214277},
    adt_obj0_fdid=777803,
    modf_unique_id=48527,
    modf_name_set=1,
    floor_fdid_base=900000500,
    piece_fdid_base=900000600,
    single_floor=True,
)

DUSTWINDCAVE = MineSpec(
    key='DustwindCave',
    wmo_fdid=111304,
    tile_fdids={0: 215223, 1: 215224, 3: 215225, 4: 215226, 5: 215227, 6: 215228, 7: 215229},
    adt_obj0_fdid=786646,
    modf_unique_id=172378,
    modf_name_set=2,
    floor_fdid_base=900000700,
    piece_fdid_base=900000800,
    single_floor=True,
)

GOLDCOASTQUARRY = MineSpec(
    key='GoldCoastQuarry',
    wmo_fdid=111137,
    tile_fdids={0: 214998, 1: 214999, 3: 215000, 4: 215001, 5: 215002, 6: 215003, 7: 215004},
    adt_obj0_fdid=777243,
    modf_unique_id=170486,
    modf_name_set=5,
    floor_fdid_base=900000900,
    piece_fdid_base=900001000,
    single_floor=True,
)

JANGOLODEMINE = MineSpec(
    key='JangolodeMine',
    wmo_fdid=110750,
    tile_fdids={0: 214595, 1: 214596, 2: 214597, 3: 214598, 4: 214599, 5: 214600, 6: 214601, 7: 214602, 8: 214603},
    adt_obj0_fdid=777438,
    modf_unique_id=16632,
    modf_name_set=4,
    floor_fdid_base=900001100,
    piece_fdid_base=900001200,
    single_floor=True,
)

JASPERLODEMINE = MineSpec(
    key='JasperlodeMine',
    wmo_fdid=111538,
    tile_fdids={0: 215383, 1: 215384, 2: 215385, 3: 215386, 4: 215387, 5: 215388, 7: 215389, 8: 215390, 9: 215391, 10: 215392, 11: 215393},
    adt_obj0_fdid=778028,
    modf_unique_id=71446,
    modf_name_set=3,
    floor_fdid_base=900001300,
    piece_fdid_base=900001400,
    single_floor=True,
)

LIGHTSHOPECHAPEL = MineSpec(
    key='LightsHopeChapel',
    wmo_fdid=106695,
    tile_fdids={0: 209852},
    adt_obj0_fdid=779648,
    modf_unique_id=200881,
    modf_name_set=0,
    floor_fdid_base=900001500,
    piece_fdid_base=900001600,
    single_floor=True,
)

NIGHTWEBSHOLLOW = MineSpec(
    key='NightWebsHollow',
    wmo_fdid=111551,
    tile_fdids={0: 215394, 1: 215395, 2: 215396, 3: 215397, 4: 215398, 5: 215399, 7: 215401, 8: 215402, 9: 215403, 10: 215404, 11: 408584},
    adt_obj0_fdid=777128,
    modf_unique_id=70052623,
    modf_name_set=2,
    floor_fdid_base=900001700,
    piece_fdid_base=900001800,
    single_floor=True,
)

THEGAPINGCHASM = MineSpec(
    key='TheGapingChasm',
    wmo_fdid=110955,
    tile_fdids={0: 214793, 1: 214794, 2: 214795, 3: 214796, 4: 214797, 5: 214798, 6: 214799, 7: 214800, 8: 214801, 9: 214802, 10: 214803, 11: 214804},
    adt_obj0_fdid=786736,
    modf_unique_id=298596,
    modf_name_set=1,
    floor_fdid_base=900001900,
    piece_fdid_base=900002000,
    single_floor=True,
)

THEGRIZZLEDDEN = MineSpec(
    key='TheGrizzledDen',
    wmo_fdid=110491,
    tile_fdids={0: 214404},
    adt_obj0_fdid=777998,
    modf_unique_id=51584,
    modf_name_set=1,
    floor_fdid_base=900002100,
    piece_fdid_base=900002200,
    single_floor=True,
)

ULDAMANAPPROACH = MineSpec(
    key='UldamanApproach',
    wmo_fdid=109758,
    tile_fdids={0: 213412, 1: 213413, 2: 213414, 3: 213415, 4: 213416, 5: 213417, 6: 213418, 7: 213419, 8: 213420, 10: 213421, 11: 213422, 12: 213423, 13: 213424, 14: 213425, 15: 213426, 16: 213427, 17: 213428, 18: 213429, 19: 213430, 20: 213431, 21: 213432, 22: 213433},
    adt_obj0_fdid=778998,
    modf_unique_id=180253,
    modf_name_set=1,
    floor_fdid_base=900002300,
    piece_fdid_base=900002400,
    single_floor=True,
)

TIRAGARDEKEEP = MineSpec(
    key='TiragardeKeep',
    wmo_fdid=111454,
    tile_fdids={0: 215331, 1: 215332, 2: 215333, 3: 215334, 4: 215335, 5: 215336, 6: 215337, 7: 215338, 8: 215339, 9: 215340, 10: 215341, 11: 215342, 13: 215343, 14: 215344, 15: 215345},
    adt_obj0_fdid=786876,
    modf_unique_id=183741,
    modf_name_set=0,
    floor_fdid_base=900002500,
    piece_fdid_base=900002600,
    single_floor=True,
)

THEMASTERSCELLAR = MineSpec(
    key='TheMastersCellar',
    wmo_fdid=114572,
    tile_fdids={1: 217703, 2: 217704, 3: 217705, 4: 217706, 5: 217707, 6: 217708},
    adt_obj0_fdid=778658,
    modf_unique_id=566705,
    modf_name_set=0,
    floor_fdid_base=900002700,
    piece_fdid_base=900002800,
    single_floor=True,
)


# Registry __main__ dispatches on — see the bottom of this file.
MINES: dict[str, MineSpec] = {
    "fargodeep": FARGODEEP,
    "echoridge": ECHO_RIDGE,
    "banethil": BANETHILBARROWDEN,
    "coldridgepass": COLDRIDGEPASS,
    "dustwind": DUSTWINDCAVE,
    "goldcoastquarry": GOLDCOASTQUARRY,
    "jangolode": JANGOLODEMINE,
    "jasperlode": JASPERLODEMINE,
    "lightshope": LIGHTSHOPECHAPEL,
    "nightwebshollow": NIGHTWEBSHOLLOW,
    "gapingchasm": THEGAPINGCHASM,
    "grizzledden": THEGRIZZLEDDEN,
    "uldamanapproach": ULDAMANAPPROACH,
    "tiragardekeep": TIRAGARDEKEEP,
    "masterscellar": THEMASTERSCELLAR,
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
                       scale: float = MINIMAP_PX_PER_UNIT,
                       bg: tuple[int, int, int, int] = (0, 0, 0, 255)) -> Image.Image:
    """Composite one floor's (or one piece's) groups onto a shared-scale canvas.

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

    ``bg`` defaults to opaque black — right for a full floor image, which is
    meant to be the only thing on screen at its sublevel and should paint
    over whatever's behind it where it has no room art. Phase 2's per-piece
    images are the opposite: many of them stack on the same sublevel range
    at once (see generate_fargodeep_pieces), so each one's "no room here"
    area must stay fully transparent (bg=(0,0,0,0)) or it would blot out
    every other piece already composited underneath it.
    """
    canvas = Image.new("RGBA", (canvas_w, canvas_h), bg)
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


def _require_discovered(spec: MineSpec) -> None:
    """Fail fast, before any network call, if *spec* is still a stub.

    Raises rather than letting ``fetch_wmo_root(None)`` etc. blow up deep
    inside a confusing traceback — see ECHO_RIDGE's comment above for what
    to fill in and how.
    """
    missing = [
        field for field, value in (
            ("wmo_fdid", spec.wmo_fdid),
            ("adt_obj0_fdid", spec.adt_obj0_fdid),
            ("modf_unique_id", spec.modf_unique_id),
            ("modf_name_set", spec.modf_name_set),
        ) if value is None
    ] + (["tile_fdids"] if not spec.tile_fdids else [])
    if missing:
        raise ValueError(
            f"MineSpec {spec.key!r} is missing {', '.join(missing)} — see "
            f"the comment above its definition in this file for how to "
            f"look them up before generating anything for it."
        )


def generate_mine_floors(spec: MineSpec, scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Fetch, parse, composite and encode *spec*'s floor(s).

    ``scale`` is Blizzard's own fixed minimap-baking scale (px/world-unit),
    not a target size to fit — see MINIMAP_PX_PER_UNIT. The canvas is
    *derived* from it (span * scale), never chosen first and fitted to.

    Writes ``WorldMap/<spec.key>/<floor>.blp`` (``upper``/``lower`` for a
    two-floor place, just ``floor`` when ``spec.single_floor``) and returns
    the Lua fragment values (layerW/layerH/tileW/tileH/cols/rows/tiles, and
    the synthetic FDID -> relative-path pairs for FDIDMap.lua) needed to
    wire them into CaveData.lua and FDIDMap.lua.
    """
    _require_discovered(spec)
    root_bytes = fetch_wmo_root(spec.wmo_fdid)
    groups = parse_wmo_groups(root_bytes, spec.tile_fdids)
    by_index = {g.index: g for g in groups}

    tiled_idx = [g.index for g in groups if g.tile_fdid is not None]

    if spec.single_floor:
        floors = {"floor": sorted(tiled_idx)}
    else:
        lower_idx, upper_idx = split_floors_by_height(groups)
        floors = {"upper": upper_idx, "lower": lower_idx}

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
    # Pre-rotation canvas size, kept for the projection block below — every
    # floor shares this exact (canvas_w, canvas_h) at this point in the
    # function, before any of them get rotated/padded.
    pre_rotate_w, pre_rotate_h = canvas_w, canvas_h

    out_dir = WORLDMAP_DIR / spec.key
    out_dir.mkdir(parents=True, exist_ok=True)

    images = {
        name: build_floor_image(
            by_index, idx, tiles, minx, maxy, canvas_w, canvas_h, scale)
        for name, idx in floors.items()
    }

    # Rotate every floor into world/true-north-up orientation. Same yaw for
    # all of them: they're floor(s) of one WMO instance, placed as a unit
    # (see world_align_rotation_degrees's docstring for why this step
    # exists and where the angle comes from).
    placement = fetch_wmo_world_placement(
        spec.adt_obj0_fdid, spec.wmo_fdid, spec.modf_unique_id)
    placement_yaw = placement.rotation[1]
    rotate_angle = world_align_rotation_degrees(placement_yaw)

    # Real per-floor worldZ ranges for CaveTable.lua's floor-selection tie
    # break — see world_z_range_for_groups's docstring for why the DB2-baked
    # bounds can't provide this themselves.
    z_ranges = {
        name: world_z_range_for_groups(by_index, idx, placement)
        for name, idx in floors.items()
    }
    images = {
        name: img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 255))
        for name, img in images.items()
    }
    # expand=True can size each floor's canvas slightly differently
    # (rotating a WxH box by a non-multiple-of-90 angle rounds bounding
    # dimensions independently) even though they were built on one shared
    # WxH canvas beforehand; pad all of them to the union so layerW/layerH
    # stays single-valued, same as CaveData.lua expects one size per place.
    out_w = max(img.width for img in images.values())
    out_h = max(img.height for img in images.values())
    for name, img in images.items():
        if img.size != (out_w, out_h):
            padded = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 255))
            padded.paste(img, (0, 0))
            images[name] = padded
    canvas_w, canvas_h = out_w, out_h

    for name, img in images.items():
        (out_dir / f"{name}.blp").write_bytes(encode_blp2_bgra(img))

    # World<->pixel projection for CaveTable.lua's GetPlayerPosition — see
    # world_align_rotation_degrees's docstring for the rotation half of this
    # and world_to_local_projection() below for the placement half. Every
    # floor shares each of these values (same WMO instance, same composite
    # pipeline, same shared pre-rotation canvas), so this is one block at
    # the *place* level, not duplicated per floor.
    projection = world_to_local_projection(
        placement, minx, maxy, scale, pre_rotate_w, pre_rotate_h,
        rotate_angle, canvas_w, canvas_h)

    # Two floors share consecutive synthetic FDIDs starting at
    # floor_fdid_base (upper, then lower) to match how FARGODEEP_UPPER/
    # _LOWER were already laid out; a single floor just consumes the one.
    floor_names = list(floors)
    fdids = {
        name: spec.floor_fdid_base + i for i, name in enumerate(floor_names)
    }

    common = dict(layerW=canvas_w, layerH=canvas_h,
                  tileW=canvas_w, tileH=canvas_h, cols=1, rows=1)
    result = {
        name: {**common, "tiles": [fdids[name]],
               "groups": sorted(idx),
               "names": [by_index[i].name for i in sorted(idx)],
               "zMin": z_ranges[name][0], "zMax": z_ranges[name][1]}
        for name, idx in floors.items()
    }
    result["fdid_map_entries"] = {
        fdid: f"{spec.key}\\{name}" for name, fdid in fdids.items()
    }
    result["canvas"] = (canvas_w, canvas_h)
    result["projection"] = projection
    # Mirrors CaveData.lua's place-level `sharedCanvas = true`: true only
    # when there's more than one floor baked from this exact same
    # composite canvas, making them eligible for the depth-slider
    # crossfade rather than a hard swap. Always false for a single-floor
    # place — there's nothing to crossfade with. Keep this in the
    # generator so a future regen doesn't silently drop/add the flag by
    # hand in CaveData.lua.
    result["sharedCanvas"] = len(floors) > 1
    return result


def generate_fargodeep(scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Back-compat alias — see ``generate_mine_floors``."""
    return generate_mine_floors(FARGODEEP, scale)


def generate_mine_pieces(spec: MineSpec, scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Bake each of *spec*'s tiled WMO groups as its own piece.

    Phase 1 baked two *floor* composites (upper.blp, lower.blp) and
    crossfaded between them as the depth slider moved. The user's Phase 2
    ask removes the floor concept from the art layer entirely: every one of
    the WMO groups that Phase 1 flattened together into those two
    composites should instead fade in and out *individually*, each on its
    own real-world-Z window, so a room's paint follows the slider on its
    own rather than in lockstep with 10+ other rooms that happen to share
    its floor label.

    The simplest correct way to get each piece positioned and rotated
    identically to how it already sits in the validated floor composite is
    to reuse that exact same pipeline per group instead of per floor:
    ``build_floor_image`` already takes an arbitrary ``group_indices``
    list (a single-group list works unchanged) and anchors that group
    against the *place's* shared ``minx``/``maxy``/``scale``/``canvas_w``/
    ``canvas_h`` — the same anchor every group already shares in
    ``generate_fargodeep``, confirmed there by both floors coming out on
    one common canvas size. Rotating each single-group canvas by the same
    ``rotate_angle`` those floors use, the same way, lands each piece's art
    at the same pixel position it already occupies inside the validated
    upper/lower composites — this is not re-derived, it is the identical
    per-group placement/rotation math generate_fargodeep already runs, just
    stopped one group early instead of compositing groups together first.

    Unlike the floor composites, each piece's canvas fills its empty area
    with full transparency (see build_floor_image's ``bg`` parameter), not
    opaque black: up to 21 of these stack on screen at once via WoW's own
    texture alpha, and an opaque-black piece would blot out every other
    piece's art already showing through underneath it. This does mean each
    piece's BLP is canvas-sized (mostly transparent) rather than tightly
    cropped to its own room — deliberately: keeping every piece anchored at
    the same (0,0) on the same shared canvas lets the renderer draw and fade
    them exactly like Phase 1 already draws/fades upper/lower, with no new
    per-piece x/y/w/h placement math in Lua at all.

    Returns the per-piece Lua fragment values (fdid, group index/name,
    zMin/zMax) plus the FDIDMap.lua entries and the shared canvas size,
    mirroring generate_mine_floors's return shape.
    """
    _require_discovered(spec)
    root_bytes = fetch_wmo_root(spec.wmo_fdid)
    groups = parse_wmo_groups(root_bytes, spec.tile_fdids)
    by_index = {g.index: g for g in groups}

    tiled_idx = sorted(i for i in by_index if by_index[i].tile_fdid is not None)
    tiles = {i: fetch_tile(by_index[i].tile_fdid) for i in tiled_idx}

    xs = [by_index[i].bbox[0] for i in tiled_idx] + \
         [by_index[i].bbox[3] for i in tiled_idx]
    ys = [by_index[i].bbox[1] for i in tiled_idx] + \
         [by_index[i].bbox[4] for i in tiled_idx]
    minx, maxy = min(xs), max(ys)
    # Same derivation as generate_mine_floors: size the (pre-rotation)
    # canvas off where each tile's native-resolution rectangle actually
    # lands, not bbox span * scale, so no tile clips.
    canvas_w = max(round((by_index[i].bbox[0] - minx) * scale) + tiles[i].width
                   for i in tiled_idx)
    canvas_h = max(round((maxy - by_index[i].bbox[4]) * scale) + tiles[i].height
                   for i in tiled_idx)

    placement = fetch_wmo_world_placement(
        spec.adt_obj0_fdid, spec.wmo_fdid, spec.modf_unique_id)
    placement_yaw = placement.rotation[1]
    rotate_angle = world_align_rotation_degrees(placement_yaw)

    out_dir = WORLDMAP_DIR / spec.key / "pieces"
    out_dir.mkdir(parents=True, exist_ok=True)

    piece_imgs: dict[int, Image.Image] = {}
    piece_z: dict[int, tuple[float, float]] = {}
    for i in tiled_idx:
        img = build_floor_image(
            by_index, [i], tiles, minx, maxy, canvas_w, canvas_h, scale,
            bg=(0, 0, 0, 0))
        img = img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 0))
        piece_imgs[i] = img
        piece_z[i] = world_z_range_for_groups(by_index, [i], placement)

    # Same union-pad safety net generate_mine_floors uses: expand=True can
    # round each single-group canvas's rotated bounding box to a slightly
    # different (w, h) even though every one started from the identical
    # pre-rotation canvas size, so pad every piece to the union.
    out_w = max(im.width for im in piece_imgs.values())
    out_h = max(im.height for im in piece_imgs.values())
    for i, img in piece_imgs.items():
        if img.size != (out_w, out_h):
            padded = Image.new("RGBA", (out_w, out_h), (0, 0, 0, 0))
            padded.paste(img, (0, 0))
            piece_imgs[i] = padded

    pieces = []
    fdid_map_entries = {}
    for order, i in enumerate(tiled_idx):
        fdid = spec.piece_fdid_base + order
        rel = f"{spec.key}\\pieces\\piece{order:02d}"
        (out_dir / f"piece{order:02d}.blp").write_bytes(
            encode_blp2_bgra(piece_imgs[i]))
        fdid_map_entries[fdid] = rel
        zmin, zmax = piece_z[i]
        pieces.append({
            "fdid": fdid, "order": order, "group": i,
            "name": by_index[i].name, "zMin": zmin, "zMax": zmax,
        })

    return {
        "pieces": pieces,
        "fdid_map_entries": fdid_map_entries,
        "canvas": (out_w, out_h),
    }


def generate_fargodeep_pieces(scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Back-compat alias — see ``generate_mine_pieces``."""
    return generate_mine_pieces(FARGODEEP, scale)


def _print_floors_result(spec: MineSpec, result: dict) -> None:
    print("canvas:", result["canvas"])
    for floor_name in [k for k in result if k not in
                        ("fdid_map_entries", "canvas", "projection", "sharedCanvas")]:
        f = result[floor_name]
        print(f"\n-- {floor_name} --")
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
    print(f"\nsharedCanvas = {result['sharedCanvas']},")


def _print_pieces_result(pieces_result: dict) -> None:
    print("\n\n== per-piece (Phase 2) ==")
    print("canvas:", pieces_result["canvas"])
    print("\n-- pieces (CaveData.lua place.pieces) --")
    for piece in pieces_result["pieces"]:
        print(f"  {{ fdid = {piece['fdid']}, group = {piece['group']}, "
              f"name = \"{piece['name']}\", "
              f"zMin = {piece['zMin']:.2f}, zMax = {piece['zMax']:.2f} }},")
    print("\n-- FDIDMap.lua entries (pieces) --")
    for fdid, rel in pieces_result["fdid_map_entries"].items():
        print(f'    [{fdid}] = "{rel}",')
    pw, ph = pieces_result["canvas"]
    print(f"\npieceCanvasW = {pw}, pieceCanvasH = {ph},")


if __name__ == "__main__":
    import sys

    key = sys.argv[1] if len(sys.argv) > 1 else "fargodeep"
    if key not in MINES:
        print(f"Unknown mine {key!r}. Known: {', '.join(MINES)}", file=sys.stderr)
        sys.exit(2)
    spec = MINES[key]

    try:
        floors_result = generate_mine_floors(spec)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    _print_floors_result(spec, floors_result)

    pieces_result = generate_mine_pieces(spec)
    _print_pieces_result(pieces_result)
