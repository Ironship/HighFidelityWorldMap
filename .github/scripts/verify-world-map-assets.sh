#!/usr/bin/env bash
# Sanity-checks the generated world map assets so a broken build is never
# published or cached. Checks src/addon/ whatever the working directory.
set -euo pipefail

cd "$(dirname "$0")/../../src/addon"

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
main=0
orig=0
for f in ${blps[@]+"${blps[@]}"}; do
  case "$f" in
    WorldMap/Original/*) orig=$((orig + 1)) ;;
    *)                   main=$((main + 1)) ;;
  esac
done
echo "Generated $main BLPs + $orig raw, $(du -sh WorldMap | cut -f1) total."

# A full build is ~687 tiles per tree. Anything far below that means
# zones failed and the package would ship with holes in it.
status=0
if (( main < 650 )); then
  echo "::error::only $main BLPs in WorldMap/, expected ~687 — refusing to publish an incomplete map"
  status=1
fi
# Generated with --original on, so an empty Original/ is a failure
# too: FDIDMap.lua would ship the background with no textures.
if (( orig < 650 )); then
  echo "::error::only $orig BLPs in WorldMap/Original/, expected ~687 — the in-game Original background would have no art"
  status=1
fi
test -s FDIDMap.lua
# Both tables have to be populated, or the addon silently drops a
# background that the TOC and the options panel still advertise.
grep -q '^HFWMF_FDID_MAP_ORIGINAL = {$' FDIDMap.lua || {
  echo "::error::FDIDMap.lua has no populated HFWMF_FDID_MAP_ORIGINAL table"
  status=1
}
exit $status
