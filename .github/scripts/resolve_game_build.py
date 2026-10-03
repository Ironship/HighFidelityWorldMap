"""Print the pinned game build and pipeline cache dir as GITHUB_OUTPUT lines.

Usage (from the repo root): python .github/scripts/resolve_game_build.py >> "$GITHUB_OUTPUT"
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from hfwm.constants import GAME_BUILD, GAME_PRODUCT  # noqa: E402

print(f"build={GAME_BUILD}")
print(f"cache_dir=.cache-{GAME_PRODUCT}-{GAME_BUILD}")
