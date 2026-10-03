#!/usr/bin/env bash
# Generator smoke tests. Run from the repo root.
#   smoke-test.sh          one interior zone through the full pipeline
#   smoke-test.sh ocean    same zone through the ocean pass
set -euo pipefail

case "${1:-default}" in
  default)
    python generateHFWM.py ./smoke --zones ThunderBluff --skip-fdid-map
    count="$(find smoke -type f -name '*.blp' | wc -l)"
    echo "Smoke build produced $count BLPs."
    # 12 for the zone, 12 again for the Original/ dump.
    if (( count != 24 )); then
      echo "::error::expected 24 BLPs from the smoke build, got $count"
      exit 1
    fi
    ;;
  ocean)
    python generateHFWM.py ./smoke-ocean --zones ThunderBluff \
      --ocean --no-original --skip-fdid-map
    test "$(find smoke-ocean -type f -name '*.blp' | wc -l)" -eq 12
    ;;
  *)
    echo "usage: $0 [ocean]" >&2
    exit 2
    ;;
esac
