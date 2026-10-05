#!/usr/bin/env bash
# Stamps the generator hash into src/addon/mapdata/FDIDMap.lua as
# HFWMF_DATA_BUILD. The core addon compares it with the X-HFWM-Data-Build line
# in the Map Data addon's TOC (stamp-mapdata-toc.sh writes the same hash there)
# and warns the player when the two differ. See src/addon/client/MapData.lua.
#
# Runs right after generation and before the tables are cached, so a cache hit
# restores an already-stamped file. Safe to run twice: an existing stamp is
# replaced, not duplicated.
#
# Inputs (environment): ART_KEY, e.g. mapart-v2-<hash>.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"
hash="${ART_KEY#mapart-v2-}"
if [[ ! "$hash" =~ ^[0-9a-f]+$ ]]; then
  echo "::error::ART_KEY '$ART_KEY' does not look like mapart-v2-<hex hash>"
  exit 1
fi

file="$(cd "$(dirname "$0")/../.." && pwd)/src/addon/mapdata/FDIDMap.lua"
test -s "$file"

tmp="$(mktemp)"
grep -v '^HFWMF_DATA_BUILD = ' "$file" > "$tmp" || true
printf 'HFWMF_DATA_BUILD = "%s"\n' "$hash" >> "$tmp"
cat "$tmp" > "$file"
rm -f "$tmp"
echo "Stamped FDIDMap.lua with HFWMF_DATA_BUILD = \"$hash\"."
