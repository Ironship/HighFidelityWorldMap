#!/usr/bin/env bash
# Deletes both world map cache entries (art and tables) for ART_KEY from main,
# so the next step regenerates them from scratch. Used by the "bypass cache"
# option of the generate workflow.
#
# Inputs (environment): ART_KEY (mapart-v2-<hash>), GH_TOKEN with actions: write.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"

for key in "$ART_KEY" "maptables-v2-${ART_KEY#mapart-v2-}"; do
  if [[ -n "$(gh cache list --ref refs/heads/main --key "$key" --json key --jq '.[].key')" ]]; then
    gh cache delete "$key" --ref refs/heads/main
  fi
done
