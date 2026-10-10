#!/usr/bin/env python3
"""
generateHFWM.py - Generate high-fidelity world map textures for WoW using
minimap satellite-view terrain data from Blizzard's CASC archives.

This is a thin entry-point that delegates to the ``hfwm`` package.
See ``hfwm/cli/main.py`` for the main orchestration logic.

Output lands in ``../addon/``: the high-resolution tile art under
``art/WorldMap/``, the low-resolution tile art under ``client/WorldMap/``
(it ships with the client), and ``client/FDIDMap.lua`` and
``client/CaveData.lua``.

Usage (from ``src/generator/``):
    python generateHFWM.py [output_dir] [--zones Zone1,Zone2] [--dry-run]
    python generateHFWM.py ../addon/art/WorldMap --lowres-dir ../addon/client/WorldMap

Requirements:
    pip install -r requirements.txt
"""

from hfwm.cli import main

if __name__ == "__main__":
    main()
