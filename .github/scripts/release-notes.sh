#!/usr/bin/env bash
# Prints the release notes for a tag to stdout: a compare link plus the commit
# subjects since the previous release of the same series (v* or mapdata-v*).
#
# Used for the GitHub Release body and, as .release-notes.md, as the packager's
# manual changelog. A manual changelog is read from the checkout instead of
# being written into the package, so no CHANGELOG.md ships in the zip.
#
# Usage: release-notes.sh <tag>      Inputs (environment): GITHUB_REPOSITORY.
set -euo pipefail

tag="${1:?usage: $0 <tag>}"
: "${GITHUB_REPOSITORY:?}"

url="https://github.com/${GITHUB_REPOSITORY}"
# "v1.2.3" -> "v", "mapdata-v1.2.3" -> "mapdata-v": everything before the first digit.
prefix="${tag%%[0-9]*}"
prev="$(git tag -l "${prefix}[0-9]*" --sort=-v:refname | grep -vxF "$tag" | while read -r t; do
  # The newest tag that is an ancestor of this one.
  git merge-base --is-ancestor "$t" "$tag" && { echo "$t"; break; }
done || true)"

if [[ -n "$prev" ]]; then
  echo "[Full Changelog](${url}/compare/${prev}...${tag})"
  echo
  git log "${prev}..${tag}" --pretty='- %s'
else
  git log "${tag}" --pretty='- %s'
fi
