#!/usr/bin/env bash
# Runs the BigWigsMods packager's release.sh on the checked-out tag, in place
# of the BigWigsMods/packager action.
#
# When a run is a push to a branch and HEAD carries a tag, release.sh prints
# "Found future tag ... not packaging" and exits 0 without building anything,
# assuming a separate tag-triggered run will package it. Both Map Data
# workflows are that tag run: release-addon-mapdata.yml pushes the tag itself
# (and the push-to-main trigger is how it normally starts), and its
# CurseForge publish is called from that same run. The action cannot get
# around the check: GITHUB_* values set in a step's `env` are shown in the log
# but the runner's own win, so only a variable set on the command line works.
#
# Usage: run-packager.sh <release.sh args...>
set -euo pipefail

script="$(mktemp)"
curl -fsSL "https://raw.githubusercontent.com/BigWigsMods/packager/v2/release.sh" -o "$script"
GITHUB_EVENT_NAME=workflow_dispatch bash "$script" "$@"
