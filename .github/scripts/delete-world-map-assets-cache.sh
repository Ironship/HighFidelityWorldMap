#!/usr/bin/env bash
# Deletes the world map art cache entry for ART_KEY from main, so the next step
# regenerates it from scratch. Used by the "bypass cache" option of the
# generate workflow.
#
# Inputs (environment): ART_KEY (mapart-v2-<hash>), GH_TOKEN with actions: write.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"

if [[ -n "$(gh cache list --ref refs/heads/main --key "$ART_KEY" --json key --jq '.[].key')" ]]; then
  gh cache delete "$ART_KEY" --ref refs/heads/main
fi
