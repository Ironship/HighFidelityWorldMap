#!/usr/bin/env bash
# Adds a checkbox task to the PR body when CurseForge metadata follow-up is
# needed, and fails until that task is checked.
#
# Inputs (env): BASE_SHA, HEAD_SHA, PR_NUMBER, GH_TOKEN, GH_REPO
set -euo pipefail

marker_start="<!-- hfwm-curseforge-metadata-task:start -->"
marker_end="<!-- hfwm-curseforge-metadata-task:end -->"

description_changed=false
logo_changed=false

if ! git diff --quiet "$BASE_SHA...$HEAD_SHA" -- docs/DESCRIPTION.md; then
  description_changed=true
fi

if ! git diff --quiet "$BASE_SHA...$HEAD_SHA" -- assets/images/icon.png; then
  logo_changed=true
fi

changed_items=()
if [[ "$description_changed" == "true" ]]; then
  changed_items+=("Description")
fi
if [[ "$logo_changed" == "true" ]]; then
  changed_items+=("Logo")
fi

needs_task=false
if (( ${#changed_items[@]} > 0 )); then
  needs_task=true
fi

join_by() {
  local IFS="$1"
  shift
  echo "$*"
}

changed_label="$(join_by ", " "${changed_items[@]:-}")"

build_block() {
  cat <<EOF
$marker_start
### CurseForge metadata follow-up

CurseForge has no API for updating these fields. This PR changes: **$changed_label**.

- [ ] I will update the CurseForge project page metadata after this PR is merged.
$marker_end
EOF
}

extract_block() {
  awk -v start="$marker_start" -v end="$marker_end" '
    $0 == start { in_block=1; print; next }
    in_block { print }
    $0 == end { in_block=0 }
  '
}

strip_block() {
  awk -v start="$marker_start" -v end="$marker_end" '
    $0 == start { in_block=1; next }
    $0 == end { in_block=0; next }
    !in_block { print }
  '
}

trim_trailing_blank_lines() {
  awk '
    { lines[NR] = $0 }
    END {
      last = NR
      while (last > 0 && lines[last] == "") {
        last--
      }
      for (i = 1; i <= last; i++) {
        print lines[i]
      }
    }
  '
}

pr_json="$(gh api "repos/$GH_REPO/pulls/$PR_NUMBER")"
pr_body="$(jq -r '.body // ""' <<<"$pr_json")"

existing_block="$(printf '%s\n' "$pr_body" | extract_block)"
body_without_block="$(printf '%s\n' "$pr_body" | strip_block | trim_trailing_blank_lines)"

updated_body="$pr_body"
if [[ "$needs_task" == "true" ]]; then
  if [[ -n "$existing_block" ]]; then
    if grep -qi '^- \[[xX]\] I will update the CurseForge project page metadata after this PR is merged\.$' <<<"$existing_block"; then
      replacement_checkbox='- [x] I will update the CurseForge project page metadata after this PR is merged.'
    else
      replacement_checkbox='- [ ] I will update the CurseForge project page metadata after this PR is merged.'
    fi

    new_block="$(build_block)"
    new_block="$(printf '%s\n' "$new_block" | sed "s#^- \[.\] I will update the CurseForge project page metadata after this PR is merged\\.\$#$replacement_checkbox#")"

    if [[ -n "$body_without_block" ]]; then
      updated_body="$body_without_block"
      updated_body+=$'\n\n'
      updated_body+="$new_block"
    else
      updated_body="$new_block"
    fi
  else
    new_block="$(build_block)"
    if [[ -n "$body_without_block" ]]; then
      updated_body="$body_without_block"
      updated_body+=$'\n\n'
      updated_body+="$new_block"
    else
      updated_body="$new_block"
    fi
  fi
else
  # If metadata no longer changes in this PR, remove any stale task block.
  updated_body="$body_without_block"
fi

if [[ "$updated_body" != "$pr_body" ]]; then
  gh api -X PATCH "repos/$GH_REPO/pulls/$PR_NUMBER" -f body="$updated_body" >/dev/null
fi

if [[ "$needs_task" != "true" ]]; then
  {
    echo "### CurseForge metadata follow-up"
    echo
    echo "No PR task required: neither \\`docs/DESCRIPTION.md\\` nor \\`assets/images/icon.png\\` has a net change in this PR."
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

current_block="$(printf '%s\n' "$updated_body" | extract_block)"

if grep -qi '^- \[[xX]\] I will update the CurseForge project page metadata after this PR is merged\.$' <<<"$current_block"; then
  {
    echo "### CurseForge metadata follow-up"
    echo
    echo "Task is checked. Metadata changed in this PR: **$changed_label**."
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

{
  echo "### CurseForge metadata follow-up"
  echo
  echo "Metadata changed in this PR: **$changed_label**."
  echo
  echo "Please check the task in the PR description to confirm you will update CurseForge after merge."
} >> "$GITHUB_STEP_SUMMARY"

echo "CurseForge metadata task is not checked in the PR body." >&2
exit 1