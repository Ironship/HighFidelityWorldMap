# Building High Fidelity World Map: Forever

This project is split into two parts:

- `src/addon/client/` — the addon (`HighFidelityWorldMap`) that hooks into the
  in-game world map. It is released as one package: the Lua code, the stitched
  World and Continent map art (the generated `WorldMap/` tile tree), and the
  generated lookup/placement tables that map the client's own minimap tiles
  onto zone and cave maps.
- `src/generator/` — the Python pipeline that generates the map tiles and FDID
  map tables. It writes the tiles into `src/addon/client/WorldMap/` and the Lua
  tables (`FDIDMap.lua`, `CaveData.lua`) into `src/addon/client/`.

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

The addon reads its tiles from `Interface\AddOns\HighFidelityWorldMap\WorldMap\`,
which is where the generator writes them (step 4), so without them the map shows
missing textures.

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

Tiles are written to `src/addon/client/WorldMap/`, and `FDIDMap.lua` and
`CaveData.lua` into `src/addon/client/`. Downloads are cached under
`src/generator/.cache-*/`.

Only the World and Continent views are stitched into art. Zone and cave maps are
drawn from the client's own minimap tiles, so the addon only carries their
placement data (`MinimapTiles.lua`, `CaveTiles.lua`), which is not part of the main
run: regenerate it from the cached zone DB with
`python src/generator/scripts/emit_minimap_tiles.py` and
`python src/generator/scripts/emit_cave_tiles.py`.

Useful flags include:

- `--zones` to process only selected maps (only the World and Continent maps produce art)
- `--dry-run` to test the pipeline without writing output
- `--refresh` to re-download cached inputs
- `--threads` to parallelize generation
- `--ocean` / `--base-art` / `--alpha-sea` for setting the sea/background behavior
- `--skip-fdid-map` for some focused local testing runs

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

The repo includes a GitHub Actions workflow that runs linting and smoke-test generation, and dry-runs the packager (`.pkgmeta`). This is the same rough validation path contributors should run locally before opening a PR.

## 8) Release packaging

Release packaging is handled by GitHub Actions workflows and the packager tool, not by a local manual compile step.

There is a single package, `HighFidelityWorldMap`, with a single tag series (`v1.2.3`). It contains the Lua and the committed tables (`FDIDMap.lua`, `CaveData.lua`). It does not contain the `WorldMap/` art or a `CHANGELOG.md`: the release notes are written to `.release-notes.md` by `.github/scripts/release-notes.sh` and given to the packager as a manual changelog (`.pkgmeta`), which uploads them without copying them into the package.

When ready to publish:

- run **Create Release: Client** (or push a `v*` tag to `main`) to package the addon, create the GitHub release (one asset, `hfwm-forever-client-v1.2.3.zip`) and then start **Publish Client Release to CurseForge** with the new tag. Manual runs take a bump and an optional prerelease suffix (for example `beta.1`) and run on `main`.
- run **Publish Client Release to CurseForge** yourself with a release's tag to retry or redo that upload to CurseForge.

The older `mapdata-v*` tags belong to the retired separate Map Data addon. The release scripts ignore them.

The `generate-world-map-assets` workflow still builds and caches the art and tables on `main` (`mapart-v2-<hash>` for `src/addon/client/WorldMap/`, `maptables-v2-<hash>` for `FDIDMap.lua` and `CaveData.lua`), but releases do not use it.

## Notes

- The generated `src/addon/client/WorldMap/` directory is a build artifact and is not normally committed.
- `src/addon/client/FDIDMap.lua` and `src/addon/client/CaveData.lua` are part of the repo and are produced by the generator.
- `src/addon/client/Libs/` is fetched during local dev and CI; none of its contents are committed.
