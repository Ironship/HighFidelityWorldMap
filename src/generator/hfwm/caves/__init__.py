"""Real (baked, offline) indoor WMO minimap art for micro-dungeon floors.

CaveData.lua's floors currently carry ``tiles`` cropped from the *outdoor*
minimap-texture pipeline (see ``hfwm/pipeline/zone.py`` / ``hfwm/gamedata/db2.py``) as a
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
re-encoded as BLP2 (via :mod:`hfwm.formats.blp`) and bundled into the addon like
any other high-fidelity art tile — so ``CaveRenderer.lua`` needs no new
code, only a ``tiles`` entry that resolves through ``FDID_MAP`` to a
bundled file instead of a live Blizzard FDID.

Scope: every parsing/compositing primitive below (``parse_wmo_groups``,
``parse_modf_placements``, ``build_floor_image``, ``world_to_local_
projection``, etc.) is generic — none of it reads a Fargodeep-specific
value directly. What *is* still per-mine is a small handful of raw
FileDataIDs (which WMO, which ADT, which minimap tiles) that identify
Fargodeep's own placement in the world; those are collected into a
``MineSpec`` (hfwm/caves/mines.py). ``MINES`` is the registry a
second micro-dungeon gets added to once its own IDs are known — see ``ECHO_RIDGE`` for a
stub showing exactly which values are still missing and how to find
them.

Modules
-------
mines     The registry: per-mine raw FileDataIDs and synthetic FDID blocks.
wmo       Pure parsing of WMO root files and ADT placements; height maths.
fetch     Pinned CASC downloads of those files and the minimap tiles.
compose   Compositing, north-up rotation and the pin projection.
bake      Orchestration: a MineSpec in, BLP2 art and Lua values out.
"""
