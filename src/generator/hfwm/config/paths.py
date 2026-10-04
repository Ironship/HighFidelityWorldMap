"""Filesystem layout: what the generator reads, caches and writes.

The repository has three parts — ``src/generator/`` (this package),
``src/addon/`` (the World of Warcraft addon it feeds) and ``src/mapdata/`` (the
separate Map Data addon that holds the tile art).  The generated Lua tables land
in ``src/addon/``, the generated tiles in ``src/mapdata/WorldMap/``; everything
it merely *caches* stays in ``src/generator/`` so it can never be packaged.
"""

from __future__ import annotations

from pathlib import Path

from .build import GAME_BUILD, GAME_PRODUCT

# config/ -> hfwm/ -> src/generator/
GENERATOR_DIR = Path(__file__).resolve().parents[2]
SRC_DIR = GENERATOR_DIR.parent
REPO_ROOT = SRC_DIR.parent
ADDON_DIR = SRC_DIR / "addon"
MAPDATA_DIR = SRC_DIR / "mapdata"

# ---------------------------------------------------------------------------
# Caches (generator-side)
# ---------------------------------------------------------------------------
# Build-stamped so retail's FDID-keyed caches can never bleed in.
CACHE_ROOT = GENERATOR_DIR / f".cache-{GAME_PRODUCT}-{GAME_BUILD}"

DB2_CACHE_DIR = CACHE_ROOT / "db2"
DONOR_DB2_CACHE_DIR = CACHE_ROOT / "donor-db2"
WDT_CACHE_DIR = CACHE_ROOT / "wdt"
MINIMAP_TILE_CACHE = CACHE_ROOT / "minimap"
MINIMAP_DB_CACHE = CACHE_ROOT / "minimap_db.json"
INTERIOR_PRESENCE_CACHE = CACHE_ROOT / "interior_presence.json"

# Blizzard's own hand-painted art-layer tiles, downloaded only when the
# base-art pass is enabled.  Same CASC endpoint as the minimap tiles and
# also keyed by FDID, so one shared directory would be safe — these are
# kept apart purely so a cache directory's name never lies about what is
# in it.
BASE_ART_TILE_CACHE = CACHE_ROOT / "baseart"

# Baked indoor-WMO art (see hfwm.caves): the WMO/ADT files themselves, and
# the per-group minimap tiles.
WMO_CACHE_DIR = CACHE_ROOT / "wmo"
WMO_TILE_CACHE_DIR = CACHE_ROOT / "wmo_minimap"

PROVENANCE_FILE = CACHE_ROOT / "provenance.json"

# ---------------------------------------------------------------------------
# Generated addon content (addon-side)
# ---------------------------------------------------------------------------
FDID_MAP_FILE = ADDON_DIR / "FDIDMap.lua"
CAVE_DATA_FILE = ADDON_DIR / "CaveData.lua"
WORLDMAP_DIR = MAPDATA_DIR / "WorldMap"

# Subdirectory of the output dir holding the raw second dump (--original).
# It cannot collide with a zone folder: zone folders are named from UiMap's
# own art-tile folder names, and the FDIDMap generator only ever looks inside
# folders it already has a zone entry for, so this one is simply passed over.
ORIGINAL_SUBDIR = "Original"
