#!/usr/bin/env bash
# Deletes the *other* release series' tags from the local checkout, so the
# packager only sees the series it is about to package.
#
# The repository has two tag series: v* (core addon) and mapdata-v* (Map Data
# addon). The packager takes the project version from the tag on the current
# commit and builds the changelog from "the previous tag" among *all* tags, with
# no option to restrict that to a prefix. Left alone, an addon changelog would
# list the commits back to the last MapData tag, and a commit carrying both
# tags would get an arbitrary version. Only the runner's local clone is touched;
# nothing is pushed.
#
# Usage: isolate-tag-series.sh <keep-prefix>     e.g. v   or   mapdata-v
set -euo pipefail

keep="${1:?usage: $0 <keep-prefix: v|mapdata-v>}"

case "$keep" in
  v)         drop="mapdata-v" ;;
  mapdata-v) drop="v" ;;
  *)         echo "::error::unknown tag series '$keep' (expected v or mapdata-v)"; exit 1 ;;
esac

# "v[0-9]*" cannot match "mapdata-v1.0.0": the glob is anchored at the start.
mapfile -t doomed < <(git tag -l "${drop}[0-9]*")
if [[ ${#doomed[@]} -gt 0 ]]; then
  git tag -d "${doomed[@]}" > /dev/null
fi
echo "Kept ${keep}* tags, removed ${#doomed[@]} ${drop}* tag(s) locally."
