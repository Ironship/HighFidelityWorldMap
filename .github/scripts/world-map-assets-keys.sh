#!/usr/bin/env bash
# Prints the art cache key for the generator hash, as a step output
# (redirect into $GITHUB_OUTPUT):
#   art-key     mapart-v2-<hash>      the art, src/addon/art/WorldMap
#
# Inputs (environment): HASH, the hashFiles() of the generator sources. The
# workflow computes it because hashFiles() is only available in expressions.
# Bump the "v2" in all places (this file and delete-world-map-assets-cache.sh)
# to invalidate the cache entry.
set -euo pipefail

: "${HASH:?HASH must be set to the hash of the generator sources}"
if [[ ! "$HASH" =~ ^[0-9a-f]+$ ]]; then
  echo "::error::generator hash '$HASH' is empty or not hexadecimal"
  exit 1
fi

echo "art-key=mapart-v2-${HASH}"
