#!/usr/bin/env bash
# Sanity-checks the generated world map assets so a broken build is never
# published or cached. Resolves its paths from the repo layout, so it works from
# any working directory.
#
# Two trees, one per addon:
#   src/addon/art/WorldMap/     the high-resolution (*HD) art, the Art addon
#   src/addon/client/WorldMap/  the low-resolution art, shipped with the client
#                               (committed; the generator rewrites it too)
# FDIDMap.lua is the client's and is not checked here.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
status=0

# verify_tree DIR NAME EXPECTED
#   DIR       addon dir holding WorldMap/
#   NAME      label for messages
#   EXPECTED  BLPs per tree (main and Original/ each) in a full build
verify_tree() {
  local dir="$1" name="$2" expected="$3"
  cd "$repo/$dir"

  # Count the two trees separately. A single total lets one of them
  # cover for the other: when every zone in phase 3 died and only the
  # Original/ dump succeeded, the combined figure still looked like a
  # half-finished build rather than a total failure of the art the
  # addon actually ships.
  # One find over the whole tree, split after the fact. Pointing find
  # at WorldMap/Original directly would exit non-zero when the dump is
  # missing, and pipefail turns that into a dead step before it can say
  # anything useful — which is the case worth reporting clearly. Counted
  # into an array rather than with `grep -c` because an empty result is
  # still one empty line, which would report 1 for a build that produced
  # nothing whatsoever.
  mapfile -t blps < <(find WorldMap -type f -name '*.blp')
  local main=0
  local orig=0
  local f
  for f in ${blps[@]+"${blps[@]}"}; do
    case "$f" in
      WorldMap/Original/*) orig=$((orig + 1)) ;;
      *)                   main=$((main + 1)) ;;
    esac
  done
  echo "$name: $main BLPs + $orig raw, $(du -sh WorldMap | cut -f1) total."

  # Anything below the full count means maps failed and the package would
  # ship with holes in it.
  if (( main < expected )); then
    echo "::error::only $main BLPs in $dir/WorldMap/, expected $expected — refusing to publish an incomplete $name map"
    status=1
  fi
  # Generated with --original on, so an empty Original/ is a failure
  # too: the client's FDIDMap.lua would offer the Raw background with no textures.
  if (( orig < expected )); then
    echo "::error::only $orig BLPs in $dir/WorldMap/Original/, expected $expected — the in-game Raw background would have no $name art"
    status=1
  fi
}

# Azeroth, Kalimdor and Eastern Kingdoms at the 32x22 grid, per tree.
verify_tree src/addon/art "high-res" 2112
# The same three at Blizzard's 4x3 grid, plus the two Continent duplicates.
verify_tree src/addon/client "low-res" 38
exit $status
