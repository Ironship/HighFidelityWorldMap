#!/usr/bin/env bash
# Prints the art cache key for the generator hash, as a step output
# (redirect into $GITHUB_OUTPUT):
#   art-key     mapart-v3-<hash>      the high-res art, src/addon/art/WorldMap
#
# Inputs (environment): HASH, the hashFiles() of the generator sources. The
# workflow computes it because hashFiles() is only available in expressions.
# Bump the "v3" in all places (this file, delete-world-map-assets-cache.sh and
# the docs in the generate workflow and action) to invalidate the cache entry.
# v3: the low-res maps moved to src/addon/client/WorldMap and left the cache.
set -euo pipefail

: "${HASH:?HASH must be set to the hash of the generator sources}"
if [[ ! "$HASH" =~ ^[0-9a-f]+$ ]]; then
  echo "::error::generator hash '$HASH' is empty or not hexadecimal"
  exit 1
fi

echo "art-key=mapart-v3-${HASH}"
