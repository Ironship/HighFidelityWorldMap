#!/usr/bin/env bash
# Prints "<tag> <art key>" for the newest Map Data release tag (mapdata-v*), or
# nothing when there is none. The art key is the `art-key:` line bump-version.sh
# stored in the annotated tag's body. A tag without one prints an empty key.
#
# Newest means most recently created, not highest version: a beta tagged after
# the stable it follows is the newest release of the art.
#
# Usage: latest-mapdata-art-key.sh <stable|any>
#   stable  only mapdata-v1.2.3, no -beta/-alpha suffix
#   any     every mapdata-v* tag
# Needs the tags fetched (a checkout with fetch-depth: 0).
set -euo pipefail

which="${1:?usage: $0 <stable|any>}"

case "$which" in
  stable) pattern='^mapdata-v[0-9]+\.[0-9]+\.[0-9]+$' ;;
  any)    pattern='^mapdata-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' ;;
  *)      echo "usage: $0 <stable|any>" >&2; exit 2 ;;
esac

tag="$(git tag -l 'mapdata-v[0-9]*' --sort=-creatordate | grep -E "$pattern" | head -n1 || true)"
[[ -n "$tag" ]] || exit 0

key="$(git for-each-ref "refs/tags/${tag}" --format='%(contents)' | sed -n 's/^art-key: *//p' | head -n1)"
echo "${tag} ${key}"
