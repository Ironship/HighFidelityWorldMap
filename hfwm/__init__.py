"""hfwm — High Fidelity World Map Forever pipeline toolkit.

A fork of the retail HFWM pipeline pinned to the "World of Warcraft
Forever" beta client.  The community listfile, AI inpainting, continent
overlays and zone presets are all gone; tile identity comes straight
from the build-pinned ``UiMapArtTile`` export instead.

Modules
-------
constants   Build pin, paths, URLs, geometry constants.
http        HTTP helpers for wago.tools DB2 + CASC downloads.
cache       Generic TTL-aware JSON file cache.
blp         BLP2 BGRA encoding.
wdt         WDT MAID chunk parser.
coordinates World <-> tile <-> pixel coordinate math.
db2         Zone database builder (DB2 join chain + WDT grids).
zone        Per-zone stitch / crop / art-layer fit / BLP encode.
fdid_map    FDIDMap.lua generation.
fmt         Human-readable size and duration formatting.
cli         CLI argument parsing and the four-phase orchestrator.
"""

__version__ = "1.0.0"
