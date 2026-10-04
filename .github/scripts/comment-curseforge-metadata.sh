#!/usr/bin/env bash
# Tells the PR author which CurseForge project-page files need a manual update,
# linking to the artifact that holds them. Writes the same text to the job
# summary, which is the only output available on fork PRs (read-only token).
#
# Inputs (env): ARTIFACT_URL, PR_NUMBER, POST_COMMENT (true|false),
#               GH_TOKEN and GH_REPO when POST_COMMENT=true
set -euo pipefail

dir=curseforge-metadata
body_file=$(mktemp)

{
  echo "### CurseForge project page needs a manual update"
  echo
  echo "CurseForge has no API for editing the description or logo, so after this PR is merged, apply the changed file(s) in the CurseForge project settings:"
  echo
  [[ -f "$dir/DESCRIPTION.md" ]] && echo "- Description: \`DESCRIPTION.md\`"
  [[ -f "$dir/icon.png" ]] && echo "- Logo: \`icon.png\`"
  echo
  echo "Download: [curseforge-metadata artifact]($ARTIFACT_URL)"
} > "$body_file"

cat "$body_file" >> "$GITHUB_STEP_SUMMARY"

if [[ "${POST_COMMENT:-false}" == "true" ]]; then
  gh pr comment "$PR_NUMBER" --edit-last --create-if-none --body-file "$body_file"
fi
