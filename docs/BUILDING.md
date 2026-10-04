# Building High Fidelity World Map: Forever

This project is split into two parts:

- a Lua addon that hooks into the in-game world map
- a Python pipeline that generates the bundled map tiles and FDID map tables

The addon itself is not a traditional "build" in the sense of compiling a binary. The real work is:

1. fetching Ace3 libraries for local dev
2. generating the map data from minimap tiles and DB2/ADT metadata
3. packaging the addon for release

## Prerequisites

- Git
- Python 3.12+
- Lua 5.1 (for syntax checks)
- A working World of Warcraft Forever beta environment for in-game testing

## 1) Clone and initialize

```sh
git clone https://github.com/Sectimus/HighFidelityWorldMapForever.git
cd HighFidelityWorldMapForever
```

## 2) Fetch Ace3 dependencies

The repo does not commit the Ace3 libraries. Fetch them before testing locally:

```sh
./dev/fetch-libs.sh
```

This populates the `Libs/` folders required for the addon to load.

## 3) Install Python dependencies

```sh
python -m pip install --upgrade pip
python -m pip install -r requirements.txt
```

## 4) Generate the map art

The generated map data is not tracked in Git and is rebuilt from source data.

```sh
python generateHFWM.py
```

Useful flags include:

- `--zones` to process only selected zones
- `--dry-run` to test the pipeline without writing output
- `--refresh` to re-download cached inputs
- `--threads` to parallelize generation
- `--ocean` / `--base-art` / `--alpha-sea` for setting the sea/background behavior
- `--skip-fdid-map` for some focused local testing runs

## 5) Local smoke tests

You can run a quick validation pass without a full world build:

```sh
python generateHFWM.py ./smoke --zones ThunderBluff --skip-fdid-map
```

This runs a small zone through the generation pipeline and checks the output is created correctly.

## 6) Lua syntax validation

You can validate the Lua files directly:

```sh
luac5.1 -p *.lua
```

or, with a loop over the addon TOC:

```sh
while IFS= read -r file; do
  [[ "$file" == *.lua ]] || continue
  luac5.1 -p "$file" || exit 1
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' HighFidelityWorldMapForever.toc | tr -d '\r')
```

## 7) CI checks

The repo includes a GitHub Actions workflow that runs linting and smoke-test generation. This is the same rough validation path contributors should run locally before opening a PR.

## 8) Release packaging

Release packaging is handled by GitHub Actions workflows and the packager tool, not by a local manual compile step.

When ready to publish:

- run **Create Release** (or push a version tag to `main`) to generate the map data, package the addon, create the GitHub release and then start **Publish Release to all Marketplaces** with the new tag
- run **Publish Release to all Marketplaces** yourself with a release's tag to retry or redo that upload to CurseForge (and any marketplaces added later)
- **Publish Release to CurseForge** does the CurseForge step on its own if you only need that one

## Notes

- The generated `WorldMap/` directory is a build artifact and is not normally committed.
- `FDIDMap.lua` is part of the repo and is produced by the generator.
- `Libs/` is fetched during local dev and CI, and is required for a clean checkout to work.
