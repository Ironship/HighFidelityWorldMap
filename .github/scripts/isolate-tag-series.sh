#!/usr/bin/env bash
# Deletes the tags of the other release series from the local checkout, so the
# packager only sees its own.
#
# The client addon (v*) and the Art addon (mapdata-v*) are released separately from
# one repository. The packager takes the project version from the tag on the
# current commit and builds the changelog from "the previous tag" among *all*
# tags, with no option to restrict that to a prefix. Left alone, a changelog
# would list the commits back to the last tag of the other series, and a commit
# carrying both would get an arbitrary version. Only the runner's local clone is
# touched; nothing is pushed.
#
# Usage: isolate-tag-series.sh <prefix-to-hide>      e.g. mapdata-v (client) or v (art)
set -euo pipefail

hide="${1:?usage: $0 <prefix-to-hide>, e.g. mapdata-v or v}"

# The glob is anchored at the start: "v[0-9]*" cannot match "mapdata-v1.0.0".
mapfile -t doomed < <(git tag -l "${hide}[0-9]*")
if [[ ${#doomed[@]} -gt 0 ]]; then
  git tag -d "${doomed[@]}" > /dev/null
fi
echo "Removed ${#doomed[@]} ${hide}* tag(s) locally."
