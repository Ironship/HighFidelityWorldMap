#!/usr/bin/env bash
# Prints the cache keys for the generated map assets, as step outputs
# (redirect into $GITHUB_OUTPUT):
#   art-key     mapart-v3-<hash>      the high-res art, src/addon/art/WorldMap
#   lowres-key  maplow-v1-<hash>      the low-res art, src/addon/client/WorldMap
#   masks-key   zonemasks-v1-<hash>   the Fog of War masks, src/addon/client/ZoneMasks
#                                     and data/ZoneShapes.lua
#
# Inputs (environment): HASH, the hashFiles() of the generator sources (art and
# low-res share it: one generator writes both); ZONES_HASH, the same for what
# the zone masks depend on. The workflow computes them because hashFiles() is
# only available in expressions.
# Bump the version in a key here, in delete-world-map-assets-cache.sh's callers
# and in the docs to invalidate that entry.
set -euo pipefail

for var in HASH ZONES_HASH; do
  if [[ ! "${!var:-}" =~ ^[0-9a-f]+$ ]]; then
    echo "::error::$var '${!var:-}' is empty or not hexadecimal"
    exit 1
  fi
done

echo "art-key=mapart-v3-${HASH}"
echo "lowres-key=maplow-v1-${HASH}"
echo "masks-key=zonemasks-v1-${ZONES_HASH}"
