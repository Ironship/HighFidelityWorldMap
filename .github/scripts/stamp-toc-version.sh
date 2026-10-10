#!/usr/bin/env bash
# Writes "## Version: <x.y.z>" into a TOC from a release tag (v1.2.3 or
# art-v1.2.3-beta.1 -> 1.2.3 / 1.2.3-beta.1). The TOCs in the repo carry no
# Version line, so a plain clone shows none; the release workflows stamp it into
# the runner's checkout just before packaging. Nothing is committed.
#
# Usage: stamp-toc-version.sh <file.toc> <release-tag>
set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <file.toc> <release-tag>" >&2; exit 2; }
toc=$1
version=${2#art-}
version=${version#v}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] || { echo "::error::Not a release tag: $2" >&2; exit 1; }

sed -i -e '/^## Version:/d' -e "/^## Author:/a ## Version: $version" "$toc"
grep -q "^## Version: $version\$" "$toc" || { echo "::error::No '## Author:' line in $toc to anchor the Version line" >&2; exit 1; }
