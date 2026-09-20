#!/usr/bin/env bash
# Fetches Echo Ridge Mine's 9 real minimap tile BLPs straight into this
# addon's own cache -- exactly where hfwm/cave_minimap.py's fetch_tile()
# (via _download_cached) already looks for them. Once these are here,
# generate_mine_floors(ECHO_RIDGE) / generate_mine_pieces(ECHO_RIDGE) can
# run without touching the network at all.
#
# Usage: just run it -- `bash fetch_echoridge_tiles.sh` or
# `./fetch_echoridge_tiles.sh` after `chmod +x`. It locates the addon
# folder itself (the directory this script lives in), the same way
# hfwm/constants.py's SCRIPT_DIR does, so it doesn't matter what your
# current directory is when you run it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="1.60.1.69913"
CACHE_DIR="$SCRIPT_DIR/.cache-wow_classic_beta-${BUILD}/wmo_minimap"
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
