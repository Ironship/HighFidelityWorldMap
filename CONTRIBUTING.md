# Contributing

## Documentation structure

This repository uses a generated root `README.md`.

- `docs/DESCRIPTION.md` is the source for the public project description.
- `docs/BUILDING.md` holds the build and local-development instructions.
- `README.md` is generated automatically and should not be edited by hand.

If you are changing the project description or build instructions, update the files in `docs/` instead of editing the generated README directly.

## Pull requests

- Keep changes focused and easy to review.
- Prefer small, targeted commits.
- Run the relevant local validation before opening a PR.

## Local validation

Typical checks include:

```sh
python -m compileall -q .github/scripts
python .github/scripts/generate_readme.py
lua -e "assert(loadfile('CaveRenderer.lua')); assert(loadfile('ResetView.lua'))"
```

This keeps the generated README and the docs source files in sync with the repo’s automation.
