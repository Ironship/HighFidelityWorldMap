#!/usr/bin/env bash
# Creates (or updates) the GitHub Release for RELEASE_TAG with exactly one
# asset: the zip the packager built (run with -d, so it uploaded nothing).
#
# The packager's own GitHub upload is not used because it always adds
# release.json next to the zip, names the zip after the project, and POSTs the
# whole file through `curl --data-binary`, which runs out of memory on the
# multi-GB Map Data zip. `gh release upload` streams the file.
#
# Usage: create-github-release.sh <asset-name>      e.g. hfwm-forever-client-v1.2.3.zip
# Inputs (environment): RELEASE_TAG, GH_TOKEN, GITHUB_REPOSITORY,
#   TAG_GLOB  tags of this release series, to find the previous release
#             for the notes (v[0-9]* or mapdata-v[0-9]*)
# Run from the checkout root, after the packager has written .release/.
set -euo pipefail

asset="${1:?usage: $0 <asset-name>}"
: "${RELEASE_TAG:?}" "${TAG_GLOB:?}" "${GITHUB_REPOSITORY:?}"

shopt -s nullglob
zips=(.release/*.zip)
if [[ ${#zips[@]} -ne 1 ]]; then
  echo "::error::Expected exactly one zip in .release/, found ${#zips[@]}"
  ls -la .release
  exit 1
fi
mv "${zips[0]}" ".release/${asset}"

# Notes: commit subjects since the previous release of the same series.
url="https://github.com/${GITHUB_REPOSITORY}"
notes="$(mktemp)"
prev="$(git tag -l "$TAG_GLOB" --sort=-v:refname | grep -vxF "$RELEASE_TAG" | while read -r t; do
  # The newest tag of the series that is an ancestor of this one.
  git merge-base --is-ancestor "$t" "$RELEASE_TAG" && { echo "$t"; break; }
done || true)"
{
  if [[ -n "$prev" ]]; then
    echo "[Full Changelog](${url}/compare/${prev}...${RELEASE_TAG})"
    echo
    git log "${prev}..${RELEASE_TAG}" --pretty='- %s'
  else
    git log "${RELEASE_TAG}" --pretty='- %s'
  fi
} > "$notes"

flags=()
[[ "${RELEASE_TAG,,}" == *alpha* || "${RELEASE_TAG,,}" == *beta* ]] && flags+=(--prerelease)

if gh release view "$RELEASE_TAG" > /dev/null 2>&1; then
  gh release edit "$RELEASE_TAG" --notes-file "$notes" "${flags[@]}"
else
  gh release create "$RELEASE_TAG" --verify-tag --title "$RELEASE_TAG" --notes-file "$notes" "${flags[@]}"
fi
gh release upload "$RELEASE_TAG" ".release/${asset}" --clobber
