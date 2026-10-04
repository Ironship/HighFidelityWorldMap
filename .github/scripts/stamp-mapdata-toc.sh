#!/usr/bin/env bash
# Writes the generator hash into the Map Data addon's TOC as
# `## X-HFWM-Data-Build: <hash>`. It is the same hash stamp-data-build.sh put in
# FDIDMap.lua, which is how the core addon notices a mismatched pair.
# Must run before the packager, which copies the TOC as it finds it.
#
# Inputs (environment): ART_KEY, e.g. mapart-v2-<hash>.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"
hash="${ART_KEY#mapart-v2-}"
if [[ ! "$hash" =~ ^[0-9a-f]+$ ]]; then
  echo "::error::ART_KEY '$ART_KEY' does not look like mapart-v2-<hex hash>"
  exit 1
fi

toc="$(cd "$(dirname "$0")/../.." && pwd)/src/addon/mapdata/HighFidelityWorldMap_MapData_Forever.toc"
if ! grep -q '^## X-HFWM-Data-Build:' "$toc"; then
  echo "::error::$toc has no '## X-HFWM-Data-Build:' line to stamp"
  exit 1
fi

sed -i "s|^## X-HFWM-Data-Build:.*|## X-HFWM-Data-Build: ${hash}|" "$toc"
grep -q "^## X-HFWM-Data-Build: ${hash}\$" "$toc"
echo "Stamped $(basename "$toc") with X-HFWM-Data-Build: $hash"
