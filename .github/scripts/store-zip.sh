#!/usr/bin/env bash
# Puts a `zip` shim first on PATH that stores instead of deflating. The map art
# is BLPs, already DXT-compressed, so deflate only burns CPU. The packager
# (release.sh) has no compression flag but calls plain `zip`. Later steps of the
# job pick the shim up through GITHUB_PATH.
set -euo pipefail

real="$(command -v zip)"
mkdir -p "$HOME/bin"
printf '#!/bin/sh\nexec %s -0 "$@"\n' "$real" > "$HOME/bin/zip"
chmod +x "$HOME/bin/zip"
echo "$HOME/bin" >> "$GITHUB_PATH"
