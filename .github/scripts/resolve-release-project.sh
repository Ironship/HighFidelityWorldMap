#!/usr/bin/env bash
# Resolves which package a release tag belongs to and what the publish workflow
# has to do for it. Writes to $GITHUB_OUTPUT:
#   project        core | mapdata
#   series         tag series prefix for isolate-tag-series.sh (v | mapdata-v)
#   require        what the Actions cache must hold (tables | all)
#   tables_only    "true" when only the small Lua tables are needed
#   packager_args  extra BigWigs packager arguments for this project
#
# core    v1.2.3          the Lua addon; ships FDIDMap.lua and CaveData.lua
# mapdata mapdata-v1.2.3  the art addon; ships src/addon/mapdata/WorldMap/
#
# Inputs (environment): RELEASE_TAG.
set -euo pipefail

: "${RELEASE_TAG:?RELEASE_TAG must be set}"

# The value is not echoed back: it is free text from a workflow input.
if [[ "$RELEASE_TAG" =~ ^mapdata-v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  {
    echo "project=mapdata"
    echo "series=mapdata-v"
    echo "require=all"
    echo "tables_only=false"
    # Same arguments as release-mapdata.yml.
    echo "packager_args=-m .pkgmeta-mapdata -n {package-name}-{project-version}:{project-version}"
  } >> "$GITHUB_OUTPUT"
elif [[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  {
    echo "project=core"
    echo "series=v"
    echo "require=tables"
    echo "tables_only=true"
    echo "packager_args="
  } >> "$GITHUB_OUTPUT"
else
  echo "::error::The release tag must look like v1.2.3, v1.2.3-beta.1, mapdata-v1.2.3 or mapdata-v1.2.3-beta.1"
  exit 1
fi
