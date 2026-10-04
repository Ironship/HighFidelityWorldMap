"""Tile and art-layer geometry."""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Source (minimap) tiles
# ---------------------------------------------------------------------------
TILE_WORLD_SIZE = 533.33333          # yards per WDT tile
MINIMAP_TILE_PX = 512                # pixels per stitched minimap tile

# Minimum accepted source-tile edge.  Some minimap tiles ship at 256px
# (see the retail project's .claude/docs/gotchas.md 1.2) — those are
# upscaled rather than dropped, so a zone never ends up with an
# unexplained hole.
MIN_SOURCE_TILE_PX = 256

# Floor for the per-region stitch resolution (see hfwm/pipeline/zone.py
# ``_effective_tile_px``).  A continent region spans up to 49x56 WDT
# tiles; stitching that at 512px/tile is a 2.9 GB canvas for a result
# that only needs a few hundred pixels, so the stitch resolution is
# halved down towards this floor.
MIN_STITCH_TILE_PX = 32

# ---------------------------------------------------------------------------
# UiMapType (Enum.UiMapType) values
# ---------------------------------------------------------------------------
UI_MAP_TYPE_WORLD = 1
UI_MAP_TYPE_CONTINENT = 2
UI_MAP_TYPE_ZONE = 3
UI_MAP_TYPE_DUNGEON = 4      # Dungeon and Micro are the two interior kinds
UI_MAP_TYPE_MICRO = 5

# ---------------------------------------------------------------------------
# Art layers
# ---------------------------------------------------------------------------
# Known-good art layer geometries for this build, derived from
# UiMapArtStyleLayer.  Used only as a sanity assertion — the real values
# are read from the DB2 at runtime.
EXPECTED_ART_LAYER_DIMS = {
    (4, 3): (1002, 668),
    (1, 1): (512, 512),
}

# Native-resolution zone maps (see hfwm/gamedata/db2.py's
# _native_zone_layer_dims and hfwm/pipeline/zone.py's use of
# zone_info["native"]).
#
# Classic-era UiMapArtStyleLayer gives every outdoor UiMap — zone, continent
# and world alike — the same tiny fixed layer (EXPECTED_ART_LAYER_DIMS
# above), typically 1002x668. Stitching a zone's minimap tiles (512px per
# 533.33yd WDT tile) down to fit that box is exactly the downscale that
# makes the world map blurrier than the minimap: the client then stretches
# those same fixed tiles back up as the player zooms in.
#
# For Type=Zone maps (UI_MAP_TYPE_ZONE above) the pipeline instead sizes
# the art layer to whatever the region's own world-space extent needs at
# the minimap's own source density — no upscale, no downscale, hence
# "native". Continent and world maps keep Blizzard's fixed layer: a
# continent's world extent at this density is the multi-GB-canvas case
# _effective_tile_px already guards against, and the scope here is zone
# maps only.
#
# Tiles are re-sliced at this size rather than the DB2's own TileWidth/
# TileHeight — 256px is Blizzard's own convention (EXPECTED_ART_LAYER_DIMS
# tiles are 256px too) and keeps BLP2 tile byte size identical to what the
# addon already ships.
NATIVE_ZONE_TILE_PX = 256

# Higher-resolution continent/world maps (see hfwm/gamedata/db2.py's
# _hires_geometry).
#
# Continent (UiMapType 2) and World (UiMapType 1) maps get the same fixed,
# tiny layer as zones -- the whole world is squeezed into the same ~1002x668
# a single zone gets -- but true native resolution there is a different
# order of problem than for zones: Kalimdor alone is 138x92 = 12,696 tiles
# at native density, and Renderer.lua creates one live Texture per tile
# every time the map is open. That is a real client-performance risk, not
# just a big download, so unlike zones these are deliberately capped rather
# than lossless.
#
# Named explicitly rather than "every Continent/World-type map": this build
# also carries Kalimdor1464 and EasternKingdoms1463, two Continent-type
# duplicates of unclear in-game use, and the point is the three maps a
# player actually means by "the continent view" -- Kalimdor, Eastern
# Kingdoms, and the top-level Azeroth map showing both at once -- not
# whatever else happens to share their UiMapType.
HIRES_CONTINENT_MAPS = frozenset({"Kalimdor", "EasternKingdoms", "Azeroth"})

# Pixel-per-axis ceiling for the maps above. Chosen to land in the same
# tile-count territory as the biggest zone map already ships (TheBarrens,
# 988 tiles) rather than the tens of thousands true native would create.
HIRES_CONTINENT_MAX_PX = 8192
