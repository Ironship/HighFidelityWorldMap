#!/usr/bin/env python3
"""
generateHFWM.py - Generate high-fidelity world map textures for WoW using
minimap satellite-view terrain data from Blizzard's CASC archives.

This is a thin entry-point that delegates to the ``hfwm`` package.
See ``hfwm/cli.py`` for the main orchestration logic.

Usage:
    python generateHFWM.py <output_dir> [--zones Zone1,Zone2] [--dry-run]
    python generateHFWM.py ./WorldMap
    python generateHFWM.py ./WorldMap --fallback-art /path/to/wow/_retail_

Requirements:
    - Pillow:    pip install Pillow
"""

from hfwm.cli import main

if __name__ == "__main__":
    main()
