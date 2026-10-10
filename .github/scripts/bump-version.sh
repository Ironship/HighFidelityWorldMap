#!/usr/bin/env bash
# Computes the next version tag, creates it and pushes it.
#
# Inputs (environment):
#   BUMP        patch|minor|major
#   PRERELEASE  optional suffix, e.g. "beta.1" -> v1.0.1-beta.1
#   TAG_PREFIX  tag series, default "v" (client); the Art addon uses "art-v"
# Writes "tag=<new tag>" to $GITHUB_OUTPUT.
set -euo pipefail

prefix="${TAG_PREFIX:-v}"
prerelease="${PRERELEASE:-}"

# "v[0-9]*" does not match "art-v1.0.0" and vice versa: the glob is anchored.
latest="$(git tag -l "${prefix}[0-9]*" --sort=-v:refname | head -n1)"
if [[ -z "$latest" ]]; then
  base="0.1.0"
else
  # Strip the prefix and any -prerelease suffix.
  core="${latest#"$prefix"}"
  core="${core%%-*}"
  IFS=. read -r major minor patch <<< "$core"
  major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
  case "$BUMP" in
    major) base="$((major + 1)).0.0" ;;
    minor) base="${major}.$((minor + 1)).0" ;;
    patch) base="${major}.${minor}.$((patch + 1))" ;;
    *) echo "::error::unknown bump '$BUMP'"; exit 1 ;;
  esac
fi

next="${prefix}${base}"
if [[ -n "$prerelease" ]]; then
  next="${next}-${prerelease#-}"
fi

if git rev-parse -q --verify "refs/tags/$next" >/dev/null; then
  echo "::error::tag $next already exists"
  exit 1
fi

echo "Previous tag: ${latest:-<none>}  ->  new tag: $next"
echo "### Releasing \`$next\` (previous: \`${latest:-none}\`)" >> "$GITHUB_STEP_SUMMARY"

git config user.name  "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
# Annotated: release.sh only recognises annotated tags as versions.
git tag -a "$next" -m "$next"
git push origin "refs/tags/$next"
echo "tag=$next" >> "$GITHUB_OUTPUT"
