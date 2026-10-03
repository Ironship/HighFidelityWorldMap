#!/usr/bin/env bash
# Fails unless the commit being released is contained in origin/main.
# Expects GITHUB_SHA and GITHUB_REF_NAME from the Actions environment.
set -euo pipefail

git fetch --no-tags --depth=1 origin main
git fetch --tags --force origin
git merge-base --is-ancestor "${GITHUB_SHA}" origin/main
echo "Tag ${GITHUB_REF_NAME} is contained in main."
