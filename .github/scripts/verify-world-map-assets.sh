#!/usr/bin/env bash
# Sanity-checks the generated world map assets so a broken build is never
# published or cached. Resolves its paths from the repo layout, so it works from
# any working directory.
#
# Checks the art in src/addon/art/WorldMap/. FDIDMap.lua is the client's, not
# the art addon's, and is not checked here.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
status=0

verify_art() {
  cd "$repo/src/addon/art"

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
  echo "Generated $main BLPs + $orig raw, $(du -sh WorldMap | cut -f1) total."

  # A full build is 2150 tiles per tree (Azeroth, Kalimdor and Eastern
  # Kingdoms at both grids, plus the two Continent duplicates). Anything far
  # below that means maps failed and the package would ship with holes in it.
  if (( main < 2000 )); then
    echo "::error::only $main BLPs in WorldMap/, expected ~2150 — refusing to publish an incomplete map"
    status=1
  fi
  # Generated with --original on, so an empty Original/ is a failure
  # too: the client's FDIDMap.lua would offer the Raw background with no textures.
  if (( orig < 2000 )); then
    echo "::error::only $orig BLPs in WorldMap/Original/, expected ~2150 — the in-game Original background would have no art"
    status=1
  fi
}

verify_art
exit $status
