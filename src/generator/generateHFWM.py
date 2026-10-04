#!/usr/bin/env python3
"""
generateHFWM.py - Generate high-fidelity world map textures for WoW using
minimap satellite-view terrain data from Blizzard's CASC archives.

This is a thin entry-point that delegates to the ``hfwm`` package.
See ``hfwm/cli/main.py`` for the main orchestration logic.

Output lands in two places: the tile art under ``../addon/mapdata/WorldMap/``
(the Map Data addon), plus ``FDIDMap.lua`` and ``CaveData.lua`` in
``../addon/``.

Usage (from ``src/generator/``):
    python generateHFWM.py [output_dir] [--zones Zone1,Zone2] [--dry-run]
    python generateHFWM.py ../addon/mapdata/WorldMap

Requirements:
    pip install -r requirements.txt
"""

from hfwm.cli import main

if __name__ == "__main__":
    main()
