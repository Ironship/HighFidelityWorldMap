# Building High Fidelity World Map: Forever

This project is split into two parts:

- `src/addon/` — the Lua addon that hooks into the in-game world map. This is
  the folder that ships, and the only one the game client sees.
- `src/generator/` — the Python pipeline that generates the bundled map tiles
  and FDID map tables. It writes its output into `src/addon/`.

Everything else (`docs/`, `assets/`, `.github/`) is repository machinery and is not packaged.

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
git clone https://github.com/Sectimus/HighFidelityWorldMap.git
cd HighFidelityWorldMap
```

## 2) Fetch Ace3 dependencies

The repo does not commit the Ace3 libraries. Fetch them before testing locally:

```sh
./src/addon/dev/fetch-libs.sh
```

This populates the `src/addon/Libs/` folders required for the addon to load.

To load the addon in the game, the client needs a folder named after the
addon with the TOC directly inside it. Link `src/addon/` into your AddOns
directory under that name:

```sh
ln -s "$PWD/src/addon" "<WoW install>/_classic_beta_/Interface/AddOns/HighFidelityWorldMap"
```

## 3) Install Python dependencies

```sh
python -m pip install --upgrade pip
python -m pip install -r src/generator/requirements.txt
```

## 4) Generate the map art

The generated map data is not tracked in Git and is rebuilt from source data.

```sh
python src/generator/generateHFWM.py
```

Tiles are written to `src/addon/WorldMap/`, alongside `src/addon/FDIDMap.lua` and
`src/addon/CaveData.lua`. Downloads are cached under `src/generator/.cache-*/`.

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
python src/generator/generateHFWM.py ./smoke --zones ThunderBluff --skip-fdid-map
```

This runs a small zone through the generation pipeline and checks the output is created correctly.

## 6) Lua syntax validation

You can validate the Lua files directly:

```sh
(cd addon && luac5.1 -p *.lua)
```

or, with a loop over the addon TOC:

```sh
while IFS= read -r file; do
  [[ "$file" == *.lua ]] || continue
  luac5.1 -p "$file" || exit 1
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' src/addon/HighFidelityWorldMap.toc | tr -d '\r')
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

- The generated `src/addon/WorldMap/` directory is a build artifact and is not normally committed.
- `src/addon/FDIDMap.lua` and `src/addon/CaveData.lua` are part of the repo and are produced by the generator.
- `src/addon/Libs/` is fetched during local dev and CI; none of its contents are committed.
