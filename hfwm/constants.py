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
PROVENANCE_FILE = CACHE_ROOT / "provenance.json"

FDID_MAP_FILE = SCRIPT_DIR / "FDIDMap.lua"
WORLDMAP_DIR = SCRIPT_DIR / "WorldMap"

# ---------------------------------------------------------------------------
# URLs
# ---------------------------------------------------------------------------
WAGO_DB2_FMT = "https://wago.tools/db2/{table}/csv?build={build}"
WAGO_CASC_FMT = "https://wago.tools/api/casc/{}"

USER_AGENT = f"HighFidelityWorldMapForever/1.0 (build {GAME_BUILD})"


def db2_url(table: str) -> str:
    """Return the build-pinned CSV export URL for a DB2 *table*."""
    return WAGO_DB2_FMT.format(table=table, build=GAME_BUILD)


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
# Cache TTLs (days)
# ---------------------------------------------------------------------------
MINIMAP_DB_CACHE_TTL_DAYS = 30
DB2_CACHE_TTL_DAYS = 30

# ---------------------------------------------------------------------------
# Network defaults
# ---------------------------------------------------------------------------
DELAY_BETWEEN_REQUESTS = 0.02   # seconds — polite delay
