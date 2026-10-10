#!/usr/bin/env bash
# Syntax-checks every Lua file listed in the TOC, plus the fetched Ace3 libs and
# the Art addon's FDIDMap.lua.
# Runs against src/addon/client/ whatever the working directory; needs luac5.1.
set -euo pipefail

cd "$(dirname "$0")/../../src/addon/client"

status=0

# Read the file list out of the TOC so a file added to the repo but
# never wired into the TOC does not silently pass.
while IFS= read -r file; do
  [[ -f "$file" ]] || { echo "::error::$file is in the TOC but missing"; status=1; continue; }
  [[ "$file" == *.lua ]] || continue
  luac5.1 -p "$file" || status=1
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' HighFidelityWorldMap.toc | tr -d '\r')

while IFS= read -r file; do
  luac5.1 -p "$file" || status=1
done < <(find Libs -name '*.lua')

# The Art addon's only Lua file (generated, committed).
luac5.1 -p ../art/FDIDMap.lua || status=1

exit $status
