#!/usr/bin/env bash
# Makes sure main's Actions cache holds the map art for ART_KEY. On a miss it
# runs generate-world-map-assets.yml on main, so the build shows up as a run of
# that workflow, and waits for it to finish. A step that merely calls the
# composite action would only appear inside the caller's own run.
#
# Needs GH_TOKEN with actions: write, and a checkout so gh can infer the repo.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set to the cache key the art is saved under}"

printf 'Generate World Map Assets?\n'

# The cache has to be visible from main: that is the only scope a tag-triggered
# run can read, and the only one the generate workflow saves to.
if [[ -n "$(gh cache list --ref refs/heads/main --key "${ART_KEY}" --json key --jq '.[].key')" ]]; then
  echo "Decision: Using the cached world map assets from main for key ${ART_KEY}."
  exit 0
fi

echo "Decision: Generating a fresh world map asset set because the cache for key ${ART_KEY} is missing on main."

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
