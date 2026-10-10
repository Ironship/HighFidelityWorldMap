# Building High Fidelity World Map: Forever

This project is split into three parts:

- `src/addon/client/` — the addon (`HighFidelityWorldMap`) that hooks into the
  in-game world map. Zone and cave views are drawn from the game's own map
  textures.
- `src/addon/art/` — the optional Art addon (`HighFidelityWorldMap_MapData_Forever`):
  just the stitched World, Eastern Kingdoms and Kalimdor map tiles and a TOC,
  kept separate so a client update is not a 1 GB download. The client
  works without it.
- `src/generator/` — the Python pipeline that generates the art and the Lua
  tables. It writes into `src/addon/art/` and `src/addon/client/`.

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

The client works on its own using the game's built-in assets. The World and
continent maps need the optional Art addon: link it the same way, or install
[hfwm-art](https://www.curseforge.com/wow/addons/hfwm-art) from CurseForge:

```sh
ln -s "$PWD/src/addon/art" "$ADDONS/HighFidelityWorldMap_MapData_Forever"
```

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

The generator writes the art (`WorldMap/`) into `src/addon/art/` and the Lua
tables (`FDIDMap.lua`, cave tile data) into `src/addon/client/`. Only the World,
Eastern Kingdoms and Kalimdor views are stitched; a full run takes about 40
minutes. Downloads are cached under `src/generator/.cache-*/`. Pass `--no-caves`
to skip `CaveData.lua` and `--skip-fdid-map` to skip `FDIDMap.lua`.

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

The repo includes a GitHub Actions workflow that runs linting and smoke-test generation, and dry-runs the packager for both addons (`.pkgmeta` and `.pkgmeta-art`). This is the same rough validation path contributors should run locally before sending changes.

## 8) Release packaging

Release packaging is handled by GitHub Actions workflows and the packager tool, not by a local manual compile step.

There are two packages, released separately so a UI or settings update does not mean re-downloading the art:

- `HighFidelityWorldMap`, the client addon, tag series `v1.2.3`. It contains the Lua and the committed tables (`FDIDMap.lua`, `CaveData.lua`, `MinimapTiles.lua`, `CaveTiles.lua`), and no binary map data.
- `HighFidelityWorldMap_MapData_Forever`, the optional Art addon (the [hfwm-art](https://www.curseforge.com/wow/addons/hfwm-art) CurseForge project), tag series `mapdata-v1.2.3`. It is only the stitched `WorldMap/` tiles for the **World**, **Eastern Kingdoms** and **Kalimdor** views and a TOC: no Lua. Zone and cave maps are drawn from the game's own files and ship no art. The client lists it under `OptionalDeps`; without it everything still works, but the World and continent maps are left to Blizzard and their options are greyed out.

When ready to publish:

- run **Create Release: Client** (or push a `v*` tag to `main`) to package the client, create the GitHub release (one asset, `hfwm-forever-client-v1.2.3.zip`) and then start **Publish Client Release to CurseForge**.
- run **Create Release: Art** (or push a `mapdata-v*` tag to `main`) to generate the art, package `.pkgmeta-art`, create the GitHub release (one asset, `hfwm-forever-mapdata-v1.2.3.zip`) and then start **Publish Art Release to CurseForge**.
- run either **Publish ... Release to CurseForge** workflow yourself with a release's tag to retry or redo that upload.

The `generate-world-map-assets` workflow builds and caches the art (`mapart-v2-<hash>`) on `main`, so an Art release only regenerates when the generator changed. Each release workflow's package step ignores the other series' tags.

## Notes

- Generated cave tile data is a build artifact and is not normally committed.
- `src/addon/client/FDIDMap.lua` and `src/addon/client/CaveData.lua` are part of the repo and are produced by the generator.
- `src/addon/art/WorldMap/` (the art) is generated and gitignored; only the Art release workflows build it.
- `src/addon/client/Libs/` is fetched during local dev and CI; none of its contents are committed.
