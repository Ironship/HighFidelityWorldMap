"""Interior (cave / dungeon) map table — see hfwm/gamedata/microdungeon.py.

This build ships Blizzard's interior map art (Interface\\WorldMap\\
MicroDungeon\\... and the instance art beside it) but its ``UiMap`` table
lists outdoor zones only: 60 rows, 1 World + 4 Continent + 55 Zone, and
not a single Dungeon or Micro.  So ``C_Map.GetBestMapForUnit`` can never
name a cave, ``C_Map.GetMapArtLayers`` can never describe one, and the
art sits in the client unreachable from Lua.

The rows that would point at it do exist — on retail, where ``UiMap``
carries 257 Micro and 897 Dungeon entries.  The interior pass borrows the
*plumbing* from retail (which floors a place has, which tiles draw
them, which area the player has to be standing in) while taking the
*art* from the pinned build, then bakes the result into CaveData.lua so
the addon can drive its own cave window with no C_Map interior support
at all.

Every borrowed row is validated against the pinned build before it is
emitted: the tile FileDataIDs must resolve on this build, the
assignment's MapID must exist in this build's ``Map``, and the names
must exist in this build's ``AreaTable``.  Anything retail has that
this build does not is dropped rather than guessed at.
"""

from __future__ import annotations

# First non-Blizzard FileDataID hfwm/caves hands out for baked cave/mine
# art (see hfwm/caves/mines.py's registry and the hfwm-add-cave skill's
# "allocate synthetic FDIDs" step). Real Blizzard FDIDs on this build top
# out in the low millions, so this block is chosen well clear of any real
# range.
#
# generate_cave_data() and generate_fdid_map() both read this to find and
# preserve hand-added cave-satellite-v2 data across a regeneration: the
# DB2-driven passes that write CaveData.lua and FDIDMap.lua know nothing
# about caves/mines above the generic fallback, so without this guard a
# plain `python3 generateHFWM.py` silently reverts every hand-upgraded
# mine back to its generic floors-only entry and drops its FDIDMap.lua
# rows entirely -- exactly what happened to Fargodeep Mine and Echo Ridge
# Mine once already (both mines' cave windows rendered solid green in
# game until this was found and reverse-engineered from git history).
SYNTHETIC_FDID_BASE = 900000000

# How many art-presence probes to run at once.  One small HTTP GET per
# candidate interior against the pinned CASC endpoint; 16 keeps the whole
# sweep under a minute without hammering wago.tools.
INTERIOR_PROBE_WORKERS = 16
