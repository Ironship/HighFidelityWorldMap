#!/usr/bin/env bash
# Works out what the generate-world-map-assets action has to do after it tried
# the caches. Prints step outputs (redirect into $GITHUB_OUTPUT):
#   art        true when the full generator has to run (HD art, and the low-res
#              maps as a by-product)
#   lowres     true when the low-res maps are written this run (a full run, or
#              the minutes-long --lowres-only run)
#   masks      true when the zone masks have to be built
#   python     true when anything needs the generator toolchain
#   verify     the trees to sanity-check: low-res and masks always, art only
#              when it was asked for
#   cache-hit  true when everything came from the cache
#
# Inputs (environment): WANT_ART (the action's `art` input: does the caller ship
# the HD art), BYPASS, and ART_HIT / LOWRES_HIT / MASKS_HIT (each restore step's
# cache-hit, empty when the step did not run).
set -euo pipefail

want_art="${WANT_ART:-true}"
bypass="${BYPASS:-false}"

# missing NAME_HIT: true when that tree has to be built.
missing() { [[ "$bypass" == "true" || "${!1:-}" != "true" ]]; }

art=false lowres=false masks=false verify="lowres masks"
if [[ "$want_art" == "true" ]]; then
  verify+=" art"
  missing ART_HIT && art=true
fi
if [[ "$art" == "true" ]] || missing LOWRES_HIT; then lowres=true; fi
if missing MASKS_HIT; then masks=true; fi

python=false
if [[ "$lowres" == "true" || "$masks" == "true" ]]; then python=true; fi

echo "art=${art}"
echo "lowres=${lowres}"
echo "masks=${masks}"
echo "python=${python}"
echo "verify=${verify}"
echo "cache-hit=$([[ "$python" == "false" ]] && echo true || echo false)"
echo "Decision: art=${art} lowres=${lowres} masks=${masks} (want art=${want_art}, bypass=${bypass})" >&2
