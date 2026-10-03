#!/usr/bin/env bash
# The map art tree is ~7 GB. The packager then copies it into .release/ and
# zips that, so a stock runner's ~14 GB runs out partway through the zip.
# Everything removed here is preinstalled tooling the job never touches.
set -euo pipefail

df -h / | tail -n1
sudo rm -rf /usr/share/dotnet /usr/local/lib/android /opt/ghc \
  /usr/local/.ghcup /opt/hostedtoolcache/CodeQL /usr/local/share/boost \
  /usr/share/swift
sudo docker image prune --all --force >/dev/null 2>&1 || true
df -h / | tail -n1
