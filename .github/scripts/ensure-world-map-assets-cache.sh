#!/usr/bin/env bash
# Makes sure main's Actions cache holds the map art for ART_KEY. On a miss it
# starts generate-world-map-assets.yml on main, so the build shows up as a run
# of that workflow, and waits for it to finish. A step that merely calls the
# composite action would only appear inside the caller's own run.
#
# Needs GH_TOKEN with actions: write, and a checkout so gh can infer the repo.
set -euo pipefail

: "${ART_KEY:?ART_KEY must be set to the cache key the art is saved under}"

workflow="generate-world-map-assets.yml"

# The cache has to be visible from main: that is the only scope a tag-triggered
# run can read, and the only one the generate workflow saves to.
if [[ -n "$(gh cache list --ref refs/heads/main --key "${ART_KEY}" --json key --jq '.[].key')" ]]; then
  echo "Cache ${ART_KEY} already exists on main."
  exit 0
fi

# Start a little early so clock skew between the runner and GitHub cannot hide
# the run we are about to create.
started="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"

echo "Cache ${ART_KEY} is missing on main; starting ${workflow}."
gh workflow run "${workflow}" --ref main

run_id=""
for _ in $(seq 1 30); do
  run_id="$(gh run list --workflow "${workflow}" --branch main --event workflow_dispatch \
    --created ">=${started}" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
  [[ -n "${run_id}" ]] && break
  sleep 10
done

if [[ -z "${run_id}" ]]; then
  echo "::error::Started ${workflow} but could not find its run."
  exit 1
fi

echo "Waiting for ${workflow} run ${run_id}: ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${run_id}"
gh run watch "${run_id}" --exit-status --interval 60 --compact
