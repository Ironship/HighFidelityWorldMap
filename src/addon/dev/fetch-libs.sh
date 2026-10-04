#!/usr/bin/env bash
# Hydrates src/addon/Libs/ with the Ace3 libraries this addon depends on, for local
# testing and CI linting. Not committed (see .gitignore).
#
# Uses a shallow, sparse clone of https://github.com/WoWUIDev/Ace3 -- the
# GitHub mirror Ace3's own project page names as its development
# repository -- so this needs only `git`, already required for this repo.
# Nothing here touches how the actual release is built: .pkgmeta's
# externals still pull from the canonical WowAce svn trunk, which is what
# Ace3's own docs say a .pkgmeta should reference. This script exists
# purely so a dev/CI checkout doesn't also need svn installed.
set -euo pipefail
cd "$(dirname "$0")/.."

mirror="https://github.com/WoWUIDev/Ace3.git"
# local dir name (matches .pkgmeta's src/addon/Libs/<name>) = path inside the mirror
paths=(
    "LibStub=LibStub"
    "CallbackHandler-1.0=CallbackHandler-1.0"
    "AceAddon-3.0=AceAddon-3.0"
    "AceEvent-3.0=AceEvent-3.0"
    "AceConsole-3.0=AceConsole-3.0"
    "AceDB-3.0=AceDB-3.0"
    "AceDBOptions-3.0=AceDBOptions-3.0"
    "AceGUI-3.0=AceGUI-3.0"
    "AceConfigRegistry-3.0=AceConfig-3.0/AceConfigRegistry-3.0"
    "AceConfigDialog-3.0=AceConfig-3.0/AceConfigDialog-3.0"
)

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Cloning $mirror (shallow, sparse)..."
git clone --quiet --depth 1 --filter=blob:none --sparse "$mirror" "$tmp/ace3"
(
    cd "$tmp/ace3"
    git sparse-checkout set --no-cone "${paths[@]#*=}"
)

mkdir -p Libs
for entry in "${paths[@]}"; do
    name="${entry%%=*}"
    src="${entry#*=}"
    echo "Installing $name..."
    rm -rf "Libs/$name"
    cp -r "$tmp/ace3/$src" "Libs/$name"
done

echo "Done. src/addon/Libs/ hydrated from the Ace3 mirror."
