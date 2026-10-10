#!/usr/bin/env bash
# Deletes the tags of the other release series from the local checkout, so the
# packager only sees its own.
#
# The client addon (v*) and the Art addon (art-v*) are released separately from
# one repository. The packager takes the project version from the tag on the
# current commit and builds the changelog from "the previous tag" among *all*
# tags, with no option to restrict that to a prefix. Left alone, a changelog
# would list the commits back to the last tag of the other series, and a commit
# carrying both would get an arbitrary version. Only the runner's local clone is
# touched; nothing is pushed.
#
# The retired mapdata-v* tags (the Art addon's old name) are hidden the same way.
#
# Usage: isolate-tag-series.sh <prefix-to-hide>...    e.g. art-v mapdata-v (client) or v mapdata-v (art)
set -euo pipefail

[[ $# -gt 0 ]] || { echo "usage: $0 <prefix-to-hide>..., e.g. art-v mapdata-v" >&2; exit 2; }

for hide in "$@"; do
  # The glob is anchored at the start: "v[0-9]*" cannot match "art-v1.0.0".
  mapfile -t doomed < <(git tag -l "${hide}[0-9]*")
  if [[ ${#doomed[@]} -gt 0 ]]; then
    git tag -d "${doomed[@]}" > /dev/null
  fi
  echo "Removed ${#doomed[@]} ${hide}* tag(s) locally."
done
