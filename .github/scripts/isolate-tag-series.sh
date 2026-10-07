#!/usr/bin/env bash
# Deletes the retired mapdata-v* tags from the local checkout, so the packager
# only sees the v* release series.
#
# The Map Data addon used to be released separately under mapdata-v* tags; it is
# now part of the client addon. Those tags still exist in the repository. The
# packager takes the project version from the tag on the current commit and
# builds the changelog from "the previous tag" among *all* tags, with no option
# to restrict that to a prefix. Left alone, a changelog would list the commits
# back to the last mapdata-v* tag, and a commit carrying both tags would get an
# arbitrary version. Only the runner's local clone is touched; nothing is
# pushed.
set -euo pipefail

# "mapdata-v[0-9]*" cannot match "v1.0.0": the glob is anchored at the start.
mapfile -t doomed < <(git tag -l "mapdata-v[0-9]*")
if [[ ${#doomed[@]} -gt 0 ]]; then
  git tag -d "${doomed[@]}" > /dev/null
fi
echo "Removed ${#doomed[@]} retired mapdata-v* tag(s) locally."
