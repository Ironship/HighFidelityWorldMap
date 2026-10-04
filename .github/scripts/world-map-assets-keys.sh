#!/usr/bin/env bash
# Prints the two cache keys for the generator hash, as step outputs
# (redirect into $GITHUB_OUTPUT):
#   art-key     mapart-v2-<hash>      the art, src/mapdata/WorldMap
#   tables-key  maptables-v2-<hash>   FDIDMap.lua and CaveData.lua
#
# Inputs (environment): HASH, the hashFiles() of the generator sources. The
# workflow computes it because hashFiles() is only available in expressions.
# Bump the "v2" in all places (this file, ensure-world-map-assets-cache.sh,
# stamp-data-build.sh, stamp-mapdata-toc.sh, delete-world-map-assets-cache.sh)
# to invalidate every cache entry at once.
set -euo pipefail

: "${HASH:?HASH must be set to the hash of the generator sources}"
if [[ ! "$HASH" =~ ^[0-9a-f]+$ ]]; then
  echo "::error::generator hash '$HASH' is empty or not hexadecimal"
  exit 1
fi

echo "art-key=mapart-v2-${HASH}"
echo "tables-key=maptables-v2-${HASH}"
