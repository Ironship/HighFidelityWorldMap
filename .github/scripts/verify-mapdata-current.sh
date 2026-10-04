#!/usr/bin/env bash
# Guard for the addon release: fails when the newest Map Data release was built
# from a different generator build than the one at this commit.
#
# The addon's FDIDMap.lua names every tile; the Map Data addon holds the tiles.
# If the generator changed and MapData has not been released from it yet, the
# addon would ship tables that point at art users cannot download.
#
# For a stable addon release only stable Map Data tags count (a user on the
# stable channel never receives a MapData beta). A prerelease addon release
# accepts the newest MapData tag of any kind.
#
# Inputs (environment): ART_KEY (mapart-v2-<hash> at this commit), RELEASE_TAG
# (the addon tag being released).
# Needs the tags fetched, so run it before isolate-tag-series.sh.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"
: "${RELEASE_TAG:?RELEASE_TAG must be set to the addon tag being released}"

if [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  which="stable"
else
  which="any"
fi

read -r tag key < <("$(dirname "$0")/latest-mapdata-art-key.sh" "$which" || true) || true
tag="${tag:-}"; key="${key:-}"

if [[ "$key" == "$ART_KEY" ]]; then
  echo "Map Data ${tag} was built from this generator build (${ART_KEY})."
  exit 0
fi

echo "::error::MapData for this generator build isn't released yet: wait for Create Release: MapData to finish or run it. (This commit's art key is ${ART_KEY}; newest ${which} MapData release is ${tag:-none}, built from ${key:-an unknown key}.)"
exit 1
