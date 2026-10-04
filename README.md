![High-Fidelity World Map logo](../assets/images/logo.png)

# High-Fidelity World Map (HFWM)

Adds a "HD/SD" toggle to view the world map pane with a detailed, high-resolution map constructed by stitching together minimap satellite imagery across entire zones. The result is a seamless, richly detailed world map that shows all the finer details of the world of Azeroth with far greater clarity than the game's default map ever could.

![HD/SD Toggle](https://i.postimg.cc/3kXr2BBY/hd-sd-toggle.jpg)

Not just individual zones, continents too, with full control and various customization options.

![Continents](https://i.postimg.cc/ZW8Y6ccq/continents.jpg)

## Fog of War support:

Exploration is at the heart of WoW. To keep the spirit of mystery alive going into forever, HFWM also comes with complete, native fog of war support!

![Fog of War](https://i.postimg.cc/0zY57ff8/fog-of-war.jpg)

## Increased zoom distance:

With all this new fidelity, the game's base zoom modifier becomes somewhat limiting, so additional zoom levels are now included!

![Zoom 1](https://i.postimg.cc/ZW8Y6cc5/zoom-1.jpg)

![Zoom 2](https://i.postimg.cc/WdGp0nnp/zoom-2.jpg)

## Optional Cave & Dungeon Art

Overlays interior cave and dungeon layouts in a classic-style, movable frame to help orient yourself below ground.

![Cave 1](https://i.postimg.cc/cvR1fmmC/cave-1.jpg)

A slider on the side can be adjusted to change the slice of cave depth you are currently viewing. Super helpful for deep, winding caves!

![Cave 2](https://i.postimg.cc/Mn7Z1DDc/cave-2.jpg)

## FAQ:

### Why do some parts of the map look wrong / glitched?

![Glitch 1](https://i.postimg.cc/cvR1fmmt/glitch-1.png)

That's just… how it actually looks on the minimap, I'm afraid.

![Glitch 2](https://i.postimg.cc/v4r85zz6/glitch-2.png)

This happens a lot throughout the game, and so I do actually want to go through and fix each issue manually eventually. This will make its way into the mod as a secondary selectable map.

Cave map controller support coming soon.

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
git clone https://github.com/Sectimus/HighFidelityWorldMapForever.git
cd HighFidelityWorldMapForever
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
ln -s "$PWD/src/addon" "<WoW install>/_classic_beta_/Interface/AddOns/HighFidelityWorldMapForever"
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
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' src/addon/HighFidelityWorldMapForever.toc | tr -d '\r')
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
