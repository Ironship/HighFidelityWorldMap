# Building High Fidelity World Map: Forever

This project is split into two parts:

- `src/addon/client/` — the addon (`HighFidelityWorldMap`) that hooks into the
  in-game world map. It is assetless for client-provided views and uses the
  game's own map textures. If custom stitched assets are needed, such as the
  World or Continent views, those are generated and delivered via the companion
  addon package.
- `src/generator/` — the Python pipeline that generates cave tile data and any
  custom stitched map assets. It writes generated output into `src/addon/client/`
  and the companion asset tree when needed.

Everything else (`docs/`, `assets/`, `.github/`) is repository machinery and is not packaged.

The addon itself is not a traditional "build" in the sense of compiling a binary. The real work is:

1. fetching Ace3 libraries for local dev
2. generating cave tile data and any required stitched assets
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
./src/addon/client/dev/fetch-libs.sh
```

This populates the `src/addon/client/Libs/` folders required for the addon to load.

To load the addon in the game, the client needs a folder named after the
addon with its TOC directly inside it. Link `src/addon/client/` into your
AddOns directory under that name:

```sh
ADDONS="<WoW install>/_classic_beta_/Interface/AddOns"
ln -s "$PWD/src/addon/client" "$ADDONS/HighFidelityWorldMap"
```

The client uses the game's built-in assets for standard map views. If custom
stitched assets are needed for the World or Continent views, the generator
produces them for the companion addon package.

## 3) Install Python dependencies

```sh
python -m pip install --upgrade pip
python -m pip install -r src/generator/requirements.txt
```

## 4) Generate cave tile data and custom assets

The generated data is not tracked in Git and is rebuilt from source data.

```sh
python src/generator/generateHFWM.py
```

The generator writes the supported outputs into `src/addon/client/`, including
the cave tile data and any Lua tables used by the addon. If custom stitched
assets are enabled, those are written for the companion addon package. Downloads
are cached under `src/generator/.cache-*/`.

If you only need to refresh the cave tile data, you can run the relevant emit
script directly from the cached zone DB:

```sh
python src/generator/scripts/emit_cave_tiles.py
```

Useful flags include:

- `--zones` to process only selected maps
- `--dry-run` to test the pipeline without writing output
- `--refresh` to re-download cached inputs
- `--threads` to parallelize generation
- `--skip-fdid-map` for focused local testing runs

## 5) Local smoke tests

You can run a quick validation pass without a full world build:

```sh
python src/generator/generateHFWM.py ./smoke --zones Kalimdor --skip-fdid-map --no-caves
```

This runs one continent through the generation pipeline and checks the output is created correctly.

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
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' src/addon/client/HighFidelityWorldMap.toc | tr -d '\r')
```

## 7) CI checks

The repo includes a GitHub Actions workflow that runs linting and smoke-test generation, and dry-runs the packager (`.pkgmeta`). This is the same rough validation path contributors should run locally before sending changes.

## 8) Release packaging

Release packaging is handled by GitHub Actions workflows and the packager tool, not by a local manual compile step.

There is a single package, `HighFidelityWorldMap`, with a single tag series (`v1.2.3`). It contains the Lua and the committed tables (`FDIDMap.lua`, `CaveData.lua`). It does not contain binary map data or a bundled `WorldMap/` tree in the client addon.

When ready to publish:

- run **Create Release: Client** (or push a `v*` tag to `main`) to package the addon, create the GitHub release (one asset, `hfwm-forever-client-v1.2.3.zip`) and then start **Publish Client Release to CurseForge**.
- run **Publish Client Release to CurseForge** yourself with a release's tag to retry or redo that upload to CurseForge.

The older `mapdata-v*` tags belong to the retired separate Map Data addon. The release scripts ignore them.

The `generate-world-map-assets` workflow still builds and caches supporting data on `main` (`maptables-v2-<hash>` for the Lua tables and any optional stitched assets for the companion addon).

## Notes

- Generated cave tile data is a build artifact and is not normally committed.
- `src/addon/client/FDIDMap.lua` and `src/addon/client/CaveData.lua` are part of the repo and are produced by the generator.
- `src/addon/client/Libs/` is fetched during local dev and CI; none of its contents are committed.
