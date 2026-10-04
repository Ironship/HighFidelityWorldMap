#!/usr/bin/env bash
# Works out what the generate-world-map-assets action has to do after it tried
# the caches. Prints step outputs (redirect into $GITHUB_OUTPUT):
#   generate     true when the generator has to run
#   cache-hit    true when everything needed came from the cache
#   verify-mode  what verify-world-map-assets.sh should check (tables|all)
#
# Inputs (environment): TABLES_HIT and ART_HIT (the restore steps' cache-hit,
# empty when the step did not run), TABLES_ONLY, LOOKUP_ONLY, BYPASS.
set -euo pipefail

tables_hit="${TABLES_HIT:-}"
art_hit="${ART_HIT:-}"
tables_only="${TABLES_ONLY:-false}"
lookup_only="${LOOKUP_ONLY:-false}"
bypass="${BYPASS:-false}"

generate=true
if [[ "$bypass" != "true" && "$tables_hit" == "true" ]]; then
  # The tables are there; the art is needed too unless the caller only ships
  # the tables.
  if [[ "$tables_only" == "true" || "$art_hit" == "true" ]]; then
    generate=false
  fi
fi

# Only the tables were actually downloaded when the art was merely looked up,
# so there is nothing under src/mapdata to check. After generation everything
# exists locally.
verify=all
if [[ "$generate" == "false" && ( "$tables_only" == "true" || "$lookup_only" == "true" ) ]]; then
  verify=tables
fi

echo "generate=${generate}"
echo "cache-hit=$([[ "$generate" == "false" ]] && echo true || echo false)"
echo "verify-mode=${verify}"
echo "Decision: generate=${generate} (tables hit='${tables_hit}', art hit='${art_hit}', tables-only=${tables_only}, lookup-only=${lookup_only}, bypass=${bypass})" >&2
