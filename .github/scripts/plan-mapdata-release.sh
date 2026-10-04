#!/usr/bin/env bash
# Decides whether a Map Data release is needed for the checked-out commit.
# Writes "release=true|false" to $GITHUB_OUTPUT.
#
# A manual run always releases. A push to main that touched src/generator/**
# releases only when the art key differs from the one recorded on the newest
# stable mapdata-v* tag. That filters out pushes which touch the generator
# folder but not the files the key hashes (tests, docs, ...).
#
# Inputs (environment): ART_KEY (mapart-v2-<hash>), GITHUB_EVENT_NAME.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set, e.g. mapart-v2-<hash>}"

decide() {
  echo "release=$1" >> "$GITHUB_OUTPUT"
  echo "### Map Data release: $1" >> "$GITHUB_STEP_SUMMARY"
  echo "$2" >> "$GITHUB_STEP_SUMMARY"
  echo "Decision: release=$1. $2"
}

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
  decide true "Manual run: always releases (art key \`$ART_KEY\`)."
  exit 0
fi

read -r tag key < <("$(dirname "$0")/latest-mapdata-art-key.sh" stable || true) || true
tag="${tag:-}"; key="${key:-}"

if [[ -z "$tag" ]]; then
  decide true "No stable Map Data release exists yet (art key \`$ART_KEY\`)."
elif [[ "$key" == "$ART_KEY" ]]; then
  decide false "Art key \`$ART_KEY\` is already released as \`$tag\`; the generator change does not alter the art."
else
  decide true "Art key \`$ART_KEY\` differs from \`${key:-none}\` on \`$tag\`."
fi
