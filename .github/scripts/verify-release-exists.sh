#!/usr/bin/env bash
# Fails unless RELEASE_TAG names an existing GitHub Release, i.e. one that the
# "Create Release" workflow has already made. Publishing never creates one.
# Inputs (environment): RELEASE_TAG, GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail

# The value is not echoed back: it is free text from a workflow input.
if [[ ! "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "::error::The release tag must look like v1.2.3 or v1.2.3-beta.1"
  exit 1
fi

if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" > /dev/null; then
  echo "::error::No GitHub release exists for that tag. Run \"Create Release\" first."
  exit 1
fi

echo "Release ${RELEASE_TAG} exists."
echo "### Publishing \`${RELEASE_TAG}\`" >> "$GITHUB_STEP_SUMMARY"
