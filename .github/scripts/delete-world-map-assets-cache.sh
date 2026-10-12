#!/usr/bin/env bash
# Deletes the world map asset cache entries named in KEYS from main, so the next
# step regenerates them from scratch. Used by the "bypass cache" option of the
# generate workflow.
#
# Inputs (environment): KEYS (space-separated, e.g. "mapart-v3-<hash> maplow-v1-<hash>"),
# GH_TOKEN with actions: write.
set -euo pipefail

: "${KEYS:?KEYS must be set}"

for key in $KEYS; do
  if [[ -n "$(gh cache list --ref refs/heads/main --key "$key" --json key --jq '.[].key')" ]]; then
    gh cache delete "$key" --ref refs/heads/main
  fi
done
