#!/usr/bin/env bash
# Works out what the generate-world-map-assets action has to do after it tried
# the cache. Prints step outputs (redirect into $GITHUB_OUTPUT):
#   generate     true when the generator has to run
#   cache-hit    true when the art came from the cache
#
# Inputs (environment): ART_HIT (the restore step's cache-hit, empty when the
# step did not run), BYPASS.
set -euo pipefail

art_hit="${ART_HIT:-}"
bypass="${BYPASS:-false}"

generate=true
if [[ "$bypass" != "true" && "$art_hit" == "true" ]]; then
  generate=false
fi

echo "generate=${generate}"
echo "cache-hit=$([[ "$generate" == "false" ]] && echo true || echo false)"
echo "Decision: generate=${generate} (art hit='${art_hit}', bypass=${bypass})" >&2
