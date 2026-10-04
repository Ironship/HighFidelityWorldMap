#!/usr/bin/env bash
# Installs the generator's Python dependencies, from src/generator/requirements.txt.
set -euo pipefail

cd "$(dirname "$0")/../../src/generator"

python -m pip install --upgrade pip
python -m pip install -r requirements.txt
