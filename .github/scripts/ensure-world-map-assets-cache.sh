#!/usr/bin/env bash
# Makes sure main's Actions cache holds the map art for ART_KEY. On a miss it
# runs generate-world-map-assets.yml on main, so the build shows up as a run of
# that workflow, and waits for it to finish. A step that merely calls the
# composite action would only appear inside the caller's own run.
#
# Needs GH_TOKEN with actions: write, and a checkout so gh can infer the repo.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set to the cache key the art is saved under}"

# The cache has to be visible from main: that is the only scope a tag-triggered
# run can read, and the only one the generate workflow saves to.
if [[ -n "$(gh cache list --ref refs/heads/main --key "${ART_KEY}" --json key --jq '.[].key')" ]]; then
  echo "Cache ${ART_KEY} already exists on main."
  exit 0
fi

echo "Cache ${ART_KEY} is missing on main."
"$(dirname "$0")/dispatch-workflow-and-wait.sh" generate-world-map-assets.yml
