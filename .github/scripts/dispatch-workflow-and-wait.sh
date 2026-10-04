#!/usr/bin/env bash
# Starts a workflow on main and waits for it to finish, failing if it fails.
# Dispatching (rather than calling it as a reusable workflow) makes it a run of
# its own workflow, visible on that workflow's page.
#
# Usage: dispatch-workflow-and-wait.sh <workflow-file> [-f key=value ...]
#
# Needs GH_TOKEN with actions: write, and a checkout so gh can infer the repo.
set -euo pipefail

workflow="${1:?usage: $0 <workflow-file> [-f key=value ...]}"
shift

# Start a little early so clock skew between the runner and GitHub cannot hide
# the run we are about to create.
started="$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"

echo "Starting ${workflow} on main."
gh workflow run "${workflow}" --ref main "$@"

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
