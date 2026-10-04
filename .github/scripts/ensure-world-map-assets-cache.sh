#!/usr/bin/env bash
# Makes sure main's Actions cache holds what a release needs for ART_KEY. On a
# miss it runs generate-world-map-assets.yml on main, so the build shows up as a
# run of that workflow, and waits for it to finish. A step that merely calls the
# composite action would only appear inside the caller's own run.
#
# Two cache entries exist per generator hash (see
# .github/actions/generate-world-map-assets): the art (ART_KEY, multi-GB) and
# the generated Lua tables (maptables-v2-<hash>, small). What has to be there
# depends on what is being released:
#   REQUIRE=tables  the core addon, which ships only the Lua tables
#   REQUIRE=all     the Map Data addon, which ships the art as well (default)
#
# Needs GH_TOKEN with actions: write, and a checkout so gh can infer the repo.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set to the cache key the art is saved under}"
require="${REQUIRE:-all}"

printf 'Generate World Map Assets?\n'

case "$require" in
  tables) keys=("maptables-v2-${ART_KEY#mapart-v2-}") ;;
  all)    keys=("maptables-v2-${ART_KEY#mapart-v2-}" "${ART_KEY}") ;;
  *)      echo "::error::REQUIRE must be tables or all"; exit 1 ;;
esac

# The cache has to be visible from main: that is the only scope a tag-triggered
# run can read, and the only one the generate workflow saves to.
missing=()
for key in "${keys[@]}"; do
  if [[ -z "$(gh cache list --ref refs/heads/main --key "${key}" --json key --jq '.[].key')" ]]; then
    missing+=("${key}")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "Decision: Using the cached world map assets from main (${keys[*]})."
  exit 0
fi

if [[ "$require" == "tables" ]]; then
  echo "::error::No cached world map tables are available for this generator build on main. Run \"Create Release: MapData\" first so the generated MapData cache exists, then rerun the client release."
  exit 1
fi

echo "Decision: Generating a fresh world map asset set because main has no cache for: ${missing[*]}"

base_ref=""
if git rev-parse --verify main >/dev/null 2>&1; then
  base_ref="main"
elif git rev-parse --verify origin/main >/dev/null 2>&1; then
  base_ref="origin/main"
fi

changed_files=()
if ! git diff --quiet -- src/generator 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard -- src/generator 2>/dev/null)" ]]; then
  mapfile -t changed_files < <({ git diff --name-only -- src/generator 2>/dev/null; git ls-files --others --exclude-standard -- src/generator 2>/dev/null; } | awk 'NF' | sort -u)
fi

if [[ ${#changed_files[@]} -eq 0 && -n "${base_ref}" ]]; then
  if git merge-base --is-ancestor "${base_ref}" HEAD 2>/dev/null; then
    mapfile -t changed_files < <({ git diff --name-only "${base_ref}...HEAD" -- src/generator 2>/dev/null; git ls-files --others --exclude-standard -- src/generator 2>/dev/null; } | awk 'NF' | sort -u)
  else
    mapfile -t changed_files < <({ git diff --name-only "${base_ref}" -- src/generator 2>/dev/null; git ls-files --others --exclude-standard -- src/generator 2>/dev/null; } | awk 'NF' | sort -u)
  fi
fi

if [[ ${#changed_files[@]} -eq 0 && $(git rev-list --count HEAD 2>/dev/null || echo 0) -gt 1 ]]; then
  mapfile -t changed_files < <({ git diff --name-only HEAD^ -- src/generator 2>/dev/null; git ls-files --others --exclude-standard -- src/generator 2>/dev/null; } | awk 'NF' | sort -u)
fi

if [[ ${#changed_files[@]} -gt 0 ]]; then
  echo "Generator files changed in this build:"
  printf '  %s\n' "${changed_files[@]}"
elif [[ -n "${base_ref}" ]]; then
  echo "Generator files changed since ${base_ref}: none detected in src/generator."
else
  echo "Generator files changed in this checkout: unable to determine a main base for comparison."
fi

echo "Dispatching generate-world-map-assets.yml on main..."
"$(dirname "$0")/dispatch-workflow-and-wait.sh" generate-world-map-assets.yml
