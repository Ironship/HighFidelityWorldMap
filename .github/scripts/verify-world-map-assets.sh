#!/usr/bin/env bash
# Sanity-checks the generated world map assets so a broken build is never
# published or cached. Resolves its paths from the repo layout, so it works from
# any working directory.
#
# The generated output lands in two addons, which is why there are two checks:
#   art     src/addon/mapdata/WorldMap/           (Map Data addon, multi-GB)
#   tables  src/addon/mapdata/FDIDMap.lua (Map Data addon, small),
#           src/addon/client/CaveData.lua (core addon, small)
#
# Usage: verify-world-map-assets.sh [tables|art|all]    (default: all)
set -euo pipefail

mode="${1:-all}"
repo="$(cd "$(dirname "$0")/../.." && pwd)"
status=0

verify_art() {
  cd "$repo/src/addon/mapdata"

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
  # too: FDIDMap.lua would ship the background with no textures.
  if (( orig < 2000 )); then
    echo "::error::only $orig BLPs in WorldMap/Original/, expected ~2150 — the in-game Original background would have no art"
    status=1
  fi
}

verify_tables() {
  # FDIDMap.lua ships in the Map Data addon, CaveData.lua in the core addon.
  local fdid="$repo/src/addon/mapdata/FDIDMap.lua"
  local cave="$repo/src/addon/client/CaveData.lua"

  test -s "$fdid" || { echo "::error::FDIDMap.lua is missing or empty"; status=1; return; }
  test -s "$cave" || { echo "::error::CaveData.lua is missing or empty"; status=1; }
  cd "$repo/src/addon/mapdata"
  # Both tables have to be populated, or the addon silently drops a
  # background that the TOC and the options panel still advertise.
  grep -q '^HFWMF_FDID_MAP_ORIGINAL = {$' FDIDMap.lua || {
    echo "::error::FDIDMap.lua has no populated HFWMF_FDID_MAP_ORIGINAL table"
    status=1
  }
  # The build stamp is what the addon compares with the Map Data addon's TOC.
  # CI stamps right after generating (stamp-data-build.sh), so an unstamped
  # table here means that step was skipped and every user would get a
  # "data does not match" warning, or none at all.
  grep -q '^HFWMF_DATA_BUILD = "[0-9a-f]\+"$' FDIDMap.lua || {
    echo "::error::FDIDMap.lua has no HFWMF_DATA_BUILD stamp"
    status=1
  }
  echo "Tables OK: FDIDMap.lua $(du -h "$fdid" | cut -f1), CaveData.lua $(du -h "$cave" 2>/dev/null | cut -f1)."
}

case "$mode" in
  tables) verify_tables ;;
  art)    verify_art ;;
  all)    verify_tables; verify_art ;;
  *)      echo "usage: $0 [tables|art|all]" >&2; exit 2 ;;
esac
exit $status
