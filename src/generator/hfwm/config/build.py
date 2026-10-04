"""The game build this generator is pinned to."""

from __future__ import annotations

# Read from _classic_beta_/.flavor.info + ../.build.info of the installed
# client.  Bump this (and delete the cache dir) when the beta patches.
GAME_PRODUCT = "wow_classic_beta"
GAME_BUILD = "1.60.1.69913"

USER_AGENT = f"HighFidelityWorldMap/1.0 (build {GAME_BUILD})"
