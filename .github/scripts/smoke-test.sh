#!/usr/bin/env bash
# Generator smoke tests. Run from the repo root; output goes to ./smoke*,
# which .gitignore covers.
#   smoke-test.sh          Kalimdor (sea, both continent grids) through the full pipeline
#   smoke-test.sh ocean    same map through the ocean-fill pass
set -euo pipefail

case "${1:-default}" in
  default)
    python src/generator/generateHFWM.py ./smoke --lowres-dir ./smoke/lowres \
      --zones Kalimdor --skip-fdid-map --no-caves
    count="$(find smoke -type f -name '*.blp' | wc -l)"
    echo "Smoke build produced $count BLPs."
    # Kalimdor is 12 Blizzard-grid tiles + 1 (Kalimdor1464) + 704 for the
    # hi-res KalimdorHD grid, and the Original/ dump repeats all of them.
    # The low-res ones land in smoke/lowres, not the client addon's WorldMap/.
    if (( count != 1434 )); then
      echo "::error::expected 1434 BLPs from the smoke build, got $count"
      exit 1
    fi
    ;;
  ocean)
    python src/generator/generateHFWM.py ./smoke-ocean \
      --lowres-dir ./smoke-ocean/lowres --zones Kalimdor \
      --ocean --no-original --skip-fdid-map --no-caves
    test "$(find smoke-ocean -type f -name '*.blp' | wc -l)" -eq 717
    ;;
  *)
    echo "usage: $0 [ocean]" >&2
    exit 2
    ;;
esac
