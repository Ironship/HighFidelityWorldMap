# Workflow rules

## No inline scripts in YAML

Workflow and composite action files (`.github/workflows/*.yml`,
`.github/actions/**/action.yml`) must not contain pasted shell, Python or other
code. Editors cannot syntax-highlight, lint or run language servers on code
embedded in a YAML string.

Put the code in a real file under `.github/scripts/` and call it from the YAML:

| Language | Location | Example |
|---|---|---|
| Shell | `.github/scripts/<name>.sh` | `run: .github/scripts/verify-map-art.sh` |
| Python | `.github/scripts/<name>.py` | `run: python .github/scripts/resolve_game_build.py >> "$GITHUB_OUTPUT"` |

Other languages follow the same pattern: a file with the proper extension,
invoked by a single `run:` line.

## Rules

- No `run: |` blocks and no heredocs. A `run:` is a single command line that
  invokes a script, or a single trivial command (for example
  `python generateHFWM.py ./WorldMap --dry-run`).
- Shell scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`, and
  are committed executable (`chmod +x`).
- Scripts run from the repo root, which is the default working directory of a
  step. Reference them by repo-relative path, including from composite actions.
- Pass inputs to scripts through `env:` (for example `BUMP`, `PRERELEASE`), not
  by interpolating `${{ ... }}` into script text. This also avoids script
  injection from untrusted inputs.
- Scripts that produce step outputs write to `$GITHUB_OUTPUT`; a Python script
  prints `key=value` lines and the step redirects them
  (`>> "$GITHUB_OUTPUT"`). Python scripts that import repo packages must put the
  repo root on `sys.path` themselves, since `python path/to/script.py` only adds
  the script's own directory.
- Keep comments explaining *why* in the script next to the code, not in the YAML.
- Add a script to a workflow's `paths:` filter when changing it should trigger
  that workflow (see the generator filter in `ci.yml`).
- Check scripts before pushing: `bash -n .github/scripts/<name>.sh` for shell,
  and run Python scripts directly where they do not need CI-only variables.
