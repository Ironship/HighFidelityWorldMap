"""Shared constants for the HFWM-Forever pipeline.

This is a fork of the retail HFWM pipeline, pinned to the
"World of Warcraft Forever" beta client.

Differences from the retail constants module:
  * Every DB2 request is pinned to :data:`GAME_BUILD`.  ``WorldMapArea``
    does not exist on this build (it 404s) and is not used at all —
    zone bounds come from ``UiMapAssignment.Region_*``.
  * All caches live under a build-stamped directory.  ``wago.tools``'
    ``/api/casc/{fdid}`` endpoint is **not** product-pinned — it serves
    whichever build was most recently ingested — so FDID-keyed caches
    from a different product must never be shared with this project.
  * No continent overlays / zone presets / terrain-phase overrides:
    those are Cataclysm-and-later retail concerns (Vashj'ir, Silithus
    phasing, the 150-tile continent art style).  Forever's world is
    vanilla Azeroth rendered with the modern UiMap art framework, and
    every art style it uses is either 1002x668 (4x3) or 512x512 (1x1).
"""

from __future__ import annotations

from pathlib import Path

# ---------------------------------------------------------------------------
# Target game build
# ---------------------------------------------------------------------------
# Read from _classic_beta_/.flavor.info + ../.build.info of the installed
# client.  Bump this (and delete the cache dir) when the beta patches.
GAME_PRODUCT = "wow_classic_beta"
GAME_BUILD = "1.60.1.69913"

# ---------------------------------------------------------------------------
# Paths (relative to the project root where generateHFWM.py lives)
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).resolve().parent.parent  # project root

# Build-stamped so retail's FDID-keyed caches can never bleed in.
CACHE_ROOT = SCRIPT_DIR / f".cache-{GAME_PRODUCT}-{GAME_BUILD}"

DB2_CACHE_DIR = CACHE_ROOT / "db2"
WDT_CACHE_DIR = CACHE_ROOT / "wdt"
MINIMAP_TILE_CACHE = CACHE_ROOT / "minimap"
MINIMAP_DB_CACHE = CACHE_ROOT / "minimap_db.json"

# Blizzard's own hand-painted art-layer tiles, downloaded only when the
# base-art pass is enabled.  Same CASC endpoint as the minimap tiles and
# also keyed by FDID, so one shared directory would be safe — these are
# kept apart purely so a cache directory's name never lies about what is
# in it.
BASE_ART_TILE_CACHE = CACHE_ROOT / "baseart"

PROVENANCE_FILE = CACHE_ROOT / "provenance.json"

FDID_MAP_FILE = SCRIPT_DIR / "FDIDMap.lua"
WORLDMAP_DIR = SCRIPT_DIR / "WorldMap"

# Subdirectory of the output dir holding the raw second dump (--original).
# It cannot collide with a zone folder: zone folders are named from UiMap's
# own art-tile folder names, and the FDIDMap generator only ever looks inside
# folders it already has a zone entry for, so this one is simply passed over.
ORIGINAL_SUBDIR = "Original"

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------
WAGO_DB2_FMT = "https://wago.tools/db2/{table}/csv?build={build}"
WAGO_DB2_LATEST_FMT = "https://wago.tools/db2/{table}/csv"
WAGO_CASC_FMT = "https://wago.tools/api/casc/{}"

# The same CASC endpoint, pinned.  ``/api/casc/{fdid}`` on its own serves
# whichever build was ingested most recently, so a file that only exists
# on retail answers 200 there and would be baked into a table claiming to
# describe this build.  With ``?build=`` it 404s instead, which is what
# makes the art-presence probe in hfwm/microdungeon.py mean anything.
WAGO_CASC_PINNED_FMT = (
    "https://wago.tools/api/casc/{fdid}?build=" + GAME_BUILD
)

USER_AGENT = f"HighFidelityWorldMapForever/1.0 (build {GAME_BUILD})"


def db2_url(table: str) -> str:
    """Return the build-pinned CSV export URL for a DB2 *table*."""
    return WAGO_DB2_FMT.format(table=table, build=GAME_BUILD)


def donor_db2_url(table: str) -> str:
    """Return the *unpinned* (latest retail) CSV export URL for *table*.

    Only the interior pass uses this, and only for map plumbing that this
    build's own tables do not carry.  Never use it for art.
    """
    return WAGO_DB2_LATEST_FMT.format(table=table)


# Tables this pipeline consumes.
DB2_TABLES = (
    "Map",
    "UiMap",
    "UiMapAssignment",
    "UiMapXMapArt",
    "UiMapArt",
    "UiMapArtStyleLayer",
    "UiMapArtTile",
)

# ---------------------------------------------------------------------------
# Interior (cave / dungeon) map table — see hfwm/microdungeon.py
# ---------------------------------------------------------------------------
# This build ships Blizzard's interior map art (Interface\WorldMap\
# MicroDungeon\... and the instance art beside it) but its ``UiMap`` table
# lists outdoor zones only: 60 rows, 1 World + 4 Continent + 55 Zone, and
# not a single Dungeon or Micro.  So ``C_Map.GetBestMapForUnit`` can never
# name a cave, ``C_Map.GetMapArtLayers`` can never describe one, and the
# art sits in the client unreachable from Lua.
#
# The rows that would point at it do exist — on retail, where ``UiMap``
# carries 257 Micro and 897 Dungeon entries.  This pass borrows the
# *plumbing* from retail (which floors a place has, which tiles draw
# them, which area the player has to be standing in) while taking the
# *art* from the pinned build, then bakes the result into CaveData.lua so
# the addon can drive its own cave window with no C_Map interior support
# at all.
#
# Every borrowed row is validated against the pinned build before it is
# emitted: the tile FileDataIDs must resolve on this build, the
# assignment's MapID must exist in this build's ``Map``, and the names
# must exist in this build's ``AreaTable``.  Anything retail has that
# this build does not is dropped rather than guessed at.
DONOR_DB2_TABLES = (
    "UiMap",
    "UiMapAssignment",
    "UiMapXMapArt",
    "UiMapArt",
    "UiMapArtStyleLayer",
    "UiMapArtTile",
    "UiMapGroupMember",
)

# Build-pinned tables the interior pass needs on top of DB2_TABLES.
INTERIOR_BUILD_DB2_TABLES = ("AreaTable",)

DONOR_DB2_CACHE_DIR = CACHE_ROOT / "donor-db2"
INTERIOR_PRESENCE_CACHE = CACHE_ROOT / "interior_presence.json"
CAVE_DATA_FILE = SCRIPT_DIR / "CaveData.lua"

# Enum.UiMapType values.  Dungeon and Micro are the two interior kinds.
UI_MAP_TYPE_ZONE = 3
UI_MAP_TYPE_DUNGEON = 4
UI_MAP_TYPE_MICRO = 5

# How many art-presence probes to run at once.  One small HTTP GET per
# candidate interior against the pinned CASC endpoint; 16 keeps the whole
# sweep under a minute without hammering wago.tools.
INTERIOR_PROBE_WORKERS = 16

# ---------------------------------------------------------------------------
# BLP2 encoding
# ---------------------------------------------------------------------------
BLP2_HEADER_SIZE = 148
BLP2_PALETTE_SIZE = 1024
BLP2_ENCODING_UNCOMPRESSED_BGRA = 3
NUM_MIP_LEVELS = 1

# ---------------------------------------------------------------------------
# Tile / coordinate geometry
# ---------------------------------------------------------------------------
TILE_WORLD_SIZE = 533.33333          # yards per WDT tile
MINIMAP_TILE_PX = 512                # pixels per stitched minimap tile

# Minimum accepted source-tile edge.  Some minimap tiles ship at 256px
# (see the retail project's .claude/docs/gotchas.md 1.2) — those are
# upscaled rather than dropped, so a zone never ends up with an
# unexplained hole.
MIN_SOURCE_TILE_PX = 256

# Floor for the per-region stitch resolution (see hfwm/zone.py
# ``_effective_tile_px``).  A continent region spans up to 49x56 WDT
# tiles; stitching that at 512px/tile is a 2.9 GB canvas for a result
# that only needs a few hundred pixels, so the stitch resolution is
# halved down towards this floor.
MIN_STITCH_TILE_PX = 32

# MAID field indices (see hfwm/wdt.py).
MAID_FIELD_MINIMAP = 7      # minimapTexture — what we want
MAID_FIELD_MAPTEXTURE = 5   # mapTexture (terrain LOD diffuse), NOT "no liquid"

# ---------------------------------------------------------------------------
# Ocean unification (see hfwm/ocean.py)
# ---------------------------------------------------------------------------
# The sea arrives in the stitch as several different flat fills, so where
# they meet you get hard rectangular seams on tile boundaries.  Measured
# over the 1858 cached minimap tiles for this build, these are the fills
# and roughly how much of the sampled pixel population each holds:
#
#   (8, 16, 16)    4.1%   open ocean — an ADT with no terrain in it
#   (26, 50, 69)   0.3%   coastal water rendered through the water shader
#   (2, 55, 70)    0.1%   deeper water over an ADT
#   (8, 20, 21)    0.1%   open ocean, second variant
#   (29, 53, 72)   0.03%  coastal water, second variant
#
# Inland lakes are deliberately absent: they carry their own tint and are
# left alone.
OCEAN_FILL_COLORS = (
    (8, 16, 16),
    (26, 50, 69),
    (2, 55, 70),
    (8, 20, 21),
    (29, 53, 72),
)

# Per-channel slack when matching the fills above.  The fills are flat and
# exact, so this only needs to absorb the ±6 dither the terrain renderer
# leaves behind; going much wider starts eating dark coastal cliff shadow.
OCEAN_FILL_TOLERANCE = 10

# The colour everything above is collapsed onto.  This is the coastal
# water fill, chosen because it is what actually abuts the coastline —
# unify onto the near-black open-ocean fill instead and every shore gets
# darker rather than the sea getting consistent.
DEFAULT_OCEAN_COLOR = (26, 50, 69)

# How much of a source tile must read as ocean before empty cells next to
# it are treated as sea.  Open-water tiles are ~100% ocean and coast tiles
# rarely exceed a third, so anything in the middle of this range works.
OCEAN_TILE_FRACTION = 0.5

# Known-good art layer geometries for this build, derived from
# UiMapArtStyleLayer.  Used only as a sanity assertion — the real values
# are read from the DB2 at runtime.
EXPECTED_ART_LAYER_DIMS = {
    (4, 3): (1002, 668),
    (1, 1): (512, 512),
}

# ---------------------------------------------------------------------------
# Native-resolution zone maps (see hfwm/db2.py's _native_zone_layer_dims and
# hfwm/zone.py's use of zone_info["native"])
# ---------------------------------------------------------------------------
# Classic-era UiMapArtStyleLayer gives every outdoor UiMap — zone, continent
# and world alike — the same tiny fixed layer (EXPECTED_ART_LAYER_DIMS
# above), typically 1002x668. Stitching a zone's minimap tiles (512px per
# 533.33yd WDT tile) down to fit that box is exactly the downscale that
# makes the world map blurrier than the minimap: the client then stretches
# those same fixed tiles back up as the player zooms in.
#
# For Type=Zone maps (UI_MAP_TYPE_ZONE below) the pipeline instead sizes the
# art layer to whatever the region's own world-space extent needs at the
# minimap's own source density — no upscale, no downscale, hence "native".
# Continent and world maps keep Blizzard's fixed layer: a continent's world
# extent at this density is the multi-GB-canvas case _effective_tile_px
# already guards against, and the scope here is zone maps only.
#
# Tiles are re-sliced at this size rather than the DB2's own TileWidth/
# TileHeight — 256px is Blizzard's own convention (EXPECTED_ART_LAYER_DIMS
# tiles are 256px too) and keeps BLP2 tile byte size identical to what the
# addon already ships.
NATIVE_ZONE_TILE_PX = 256

# ---------------------------------------------------------------------------
# Cache TTLs (days)
# ---------------------------------------------------------------------------
MINIMAP_DB_CACHE_TTL_DAYS = 30
DB2_CACHE_TTL_DAYS = 30

# The donor tables track retail, which patches far more often than this
# beta does, but nothing the interior pass reads out of them (floor
# order, area names, tile FDIDs for vanilla content) has changed in
# years.  A long TTL keeps a ~13 MB UiMapArtTile download off every run;
# --refresh-caves forces it when that assumption needs testing.
DONOR_DB2_CACHE_TTL_DAYS = 30
INTERIOR_PRESENCE_CACHE_TTL_DAYS = 30

# ---------------------------------------------------------------------------
# Network defaults
# ---------------------------------------------------------------------------
DELAY_BETWEEN_REQUESTS = 0.02   # seconds — polite delay
