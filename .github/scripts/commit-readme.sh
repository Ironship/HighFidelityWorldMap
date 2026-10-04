#!/usr/bin/env bash
# README.md is generated from docs/ and intentionally not kept in the local git
# state. This script exits without touching branch history so contributors do not
# end up with a divergent README commit after a CI regeneration.
set -euo pipefail

echo "README.md is generated from docs/ and should not be committed to local git state."
echo "Regenerate it with: python .github/scripts/generate_readme.py"
