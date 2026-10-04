"""Print the pinned game build and pipeline cache dir as GITHUB_OUTPUT lines.

Usage (from anywhere): python .github/scripts/resolve_game_build.py >> "$GITHUB_OUTPUT"

``cache_dir`` is relative to the repository root, which is where the cache
action runs.
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "src" / "generator"))

from hfwm.config.build import GAME_BUILD  # noqa: E402
from hfwm.config.paths import CACHE_ROOT  # noqa: E402

print(f"build={GAME_BUILD}")
print(f"cache_dir={CACHE_ROOT.relative_to(REPO_ROOT).as_posix()}")
