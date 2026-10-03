#!/usr/bin/env bash
# Syntax-checks every Lua file listed in the TOC, plus the fetched Ace3 libs.
# Run from the repo root with luac5.1 installed.
set -euo pipefail

status=0

# Read the file list out of the TOC so a file added to the repo but
# never wired into the TOC does not silently pass.
while IFS= read -r file; do
  [[ -f "$file" ]] || { echo "::error::$file is in the TOC but missing"; status=1; continue; }
  [[ "$file" == *.lua ]] || continue
  luac5.1 -p "$file" || status=1
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' HighFidelityWorldMapForever.toc | tr -d '\r')

while IFS= read -r file; do
  luac5.1 -p "$file" || status=1
done < <(find Libs -name '*.lua')

exit $status
