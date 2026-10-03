#!/usr/bin/env bash
# Commits and pushes the regenerated README.md, if it changed.
set -euo pipefail

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add README.md
if git diff --cached --quiet; then
  echo "No README changes generated."
  exit 0
fi
git commit -m "Generate README from docs"
git push
