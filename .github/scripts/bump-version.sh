#!/usr/bin/env bash
# Computes the next version tag, creates it and pushes it.
#
# Inputs (environment):
#   BUMP        patch|minor|major
#   PRERELEASE  optional suffix, e.g. "beta.1" -> <prefix>1.0.1-beta.1
#   TAG_PREFIX  which tag series this is. Default "v" (the core addon, v1.2.3).
#               The Map Data addon uses "mapdata-v".
#   TAG_NOTE    optional text for the annotated tag's body. The Map Data
#               release records "art-key: mapart-v2-<hash>" here, which is how
#               plan-mapdata-release.sh and verify-mapdata-current.sh later tell
#               what art a tag was built from.
# Writes "tag=<new tag>" to $GITHUB_OUTPUT.
set -euo pipefail

prefix="${TAG_PREFIX:-v}"
prerelease="${PRERELEASE:-}"
note="${TAG_NOTE:-}"

# Only this series: "v[0-9]*" does not match "mapdata-v1.0.0", and the other
# way round, so the two version lines never see each other.
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
if [[ -n "$note" ]]; then
  git tag -a "$next" -m "$next" -m "$note"
else
  git tag -a "$next" -m "$next"
fi
git push origin "refs/tags/$next"
echo "tag=$next" >> "$GITHUB_OUTPUT"
