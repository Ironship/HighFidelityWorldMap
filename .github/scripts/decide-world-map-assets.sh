#!/usr/bin/env bash
# Works out what the generate-world-map-assets action has to do after it tried
# the caches. Prints step outputs (redirect into $GITHUB_OUTPUT):
#   generate     true when the generator has to run
#   cache-hit    true when everything needed came from the cache
#
# Inputs (environment): TABLES_HIT and ART_HIT (the restore steps' cache-hit,
# empty when the step did not run), BYPASS.
set -euo pipefail

tables_hit="${TABLES_HIT:-}"
art_hit="${ART_HIT:-}"
bypass="${BYPASS:-false}"

# Both entries are needed: the tables and the art ship in the same package.
generate=true
if [[ "$bypass" != "true" && "$tables_hit" == "true" && "$art_hit" == "true" ]]; then
  generate=false
fi

echo "generate=${generate}"
echo "cache-hit=$([[ "$generate" == "false" ]] && echo true || echo false)"
echo "Decision: generate=${generate} (tables hit='${tables_hit}', art hit='${art_hit}', bypass=${bypass})" >&2
