#!/usr/bin/env bash
# Fetches Echo Ridge Mine's 9 real minimap tile BLPs straight into the
# generator's cache -- exactly where hfwm/caves/fetch.py's fetch_tile()
# already looks for them. Once these are here,
# generate_mine_floors(ECHO_RIDGE) / generate_mine_pieces(ECHO_RIDGE) can
# run without touching the network at all.
#
# Usage: just run it -- `bash src/generator/scripts/fetch_echoridge_tiles.sh`.
# The pinned build and the cache location come from the generator's own
# config (hfwm/config), so they cannot drift from what the generator reads.

set -euo pipefail

GENERATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$(cd "$GENERATOR_DIR" && python3 -c 'from hfwm.config.build import GAME_BUILD; print(GAME_BUILD)')"
CACHE_DIR="$(cd "$GENERATOR_DIR" && python3 -c 'from hfwm.config.paths import WMO_TILE_CACHE_DIR; print(WMO_TILE_CACHE_DIR)')"
mkdir -p "$CACHE_DIR"

# WMO group index (0-8) -> FileDataID, for Echo Ridge Mine's
# world/wmo/dungeon/md_goldmine/md_goldmine.wmo (FDID 110750).
FDIDS=(214595 214596 214597 214598 214599 214600 214601 214602 214603)

ok=0
for fdid in "${FDIDS[@]}"; do
    out="$CACHE_DIR/${fdid}.blp"
    if [[ -s "$out" ]]; then
        echo "already cached: $fdid"
        ok=$((ok + 1))
        continue
    fi
    echo "fetching $fdid ..."
    if curl -sSf -o "$out" "https://wago.tools/api/casc/${fdid}?build=${BUILD}"; then
        ok=$((ok + 1))
    else
        echo "  FAILED: $fdid" >&2
        rm -f "$out"
    fi
done

echo
echo "$ok/${#FDIDS[@]} tiles present in $CACHE_DIR"
