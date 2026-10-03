#!/usr/bin/env bash
# Copies the CurseForge project-page files that this PR changed into
# curseforge-metadata/ so they can be uploaded as an artifact.
#
# CurseForge has no API for editing the project description or logo, so these
# have to be applied by hand in the CurseForge project settings.
#
# Inputs (env): BASE_SHA, HEAD_SHA
# Outputs ($GITHUB_OUTPUT): changed=true|false
set -euo pipefail

out_dir=curseforge-metadata
files=(docs/DESCRIPTION.md assets/images/logo.png)

rm -rf "$out_dir"
mkdir -p "$out_dir"

changed=false
for f in "${files[@]}"; do
  # A path filter on the workflow only guarantees one of these was touched at
  # some point in the PR; confirm the net diff is non-empty. Deleted files are
  # skipped because there is nothing to upload.
  if ! git diff --quiet "$BASE_SHA...$HEAD_SHA" -- "$f" && [[ -f "$f" ]]; then
    cp "$f" "$out_dir/$(basename "$f")"
    changed=true
  fi
done

echo "changed=$changed" >> "$GITHUB_OUTPUT"
