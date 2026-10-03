#!/usr/bin/env bash
# Installs the generator's Python dependencies. Run from the repo root.
set -euo pipefail

python -m pip install --upgrade pip
python -m pip install -r requirements.txt
