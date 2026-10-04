#!/usr/bin/env bash
# Fails unless the commit a release tag points at is contained in origin/main.
# The tag is RELEASE_TAG when set (publishing an existing release), otherwise
# GITHUB_REF_NAME (the run was triggered by the tag push itself).
set -euo pipefail

tag="${RELEASE_TAG:-${GITHUB_REF_NAME}}"

# Not --depth=1: a published release is usually older than main's tip, and a
# shallow main would make every commit but the tip look like it is not on main.
git fetch --no-tags origin main
git fetch --tags --force origin
git merge-base --is-ancestor "refs/tags/${tag}^{commit}" origin/main
echo "Tag ${tag} is contained in main."
