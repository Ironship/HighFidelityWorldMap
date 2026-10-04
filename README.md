![High-Fidelity World Map logo](assets/images/logo.png)

# High-Fidelity World Map (HFWM)

[![CurseForge Downloads](https://img.shields.io/curseforge/dt/1701034?color=orange&logo=curseforge&style=flat-square)](https://www.curseforge.com/projects/1701034)

Adds a "HD/SD" toggle to view the world map pane with a detailed, high-resolution map constructed by stitching together minimap satellite imagery across entire zones. The result is a seamless, richly detailed world map that shows all the finer details of the world of Azeroth with far greater clarity than the game's default map ever could.

![HD/SD Toggle](https://i.postimg.cc/3kXr2BBY/hd-sd-toggle.jpg)

## Requires Map Data

The map art ships as a separate addon, [High Fidelity World Map Art](https://www.curseforge.com/wow/addons/high-fidelity-world-map-art) (`HighFidelityWorldMap_MapData_Forever`), because it is large and rarely changes. CurseForge and most addon managers install it automatically as a dependency. If you install by hand, install both. HFWM prints a warning in chat when the Map Data addon is missing or out of date.

## Fog of War support:

Exploration is at the heart of WoW. To keep the spirit of mystery alive going into forever, HFWM also comes with complete, native fog of war support!

![Fog of War](https://i.postimg.cc/0zY57ff8/fog-of-war.jpg)

## Offers optional replacements for *all* maps

Not just individual zones, continents too! With full control and various customization options.

![Continents](https://i.postimg.cc/ZW8Y6ccq/continents.jpg)

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

This project is split into three parts:

- `src/addon/client/` — the Lua addon that hooks into the in-game world map
  (`HighFidelityWorldMap`). Small, and released on its own.
- `src/addon/mapdata/` — the Map Data addon (`HighFidelityWorldMap_MapData_Forever`):
  the generated map art and nothing else, a TOC and the `WorldMap/` tile tree.
  It is large (several GB), changes rarely, and has its own CurseForge project,
  tags and version, so a UI or settings update does not mean re-downloading the
  art. The core addon reads the tiles from it by file path.
- `src/generator/` — the Python pipeline that generates the map tiles and FDID
  map tables. It writes the tiles into `src/addon/mapdata/WorldMap/` and the Lua
  tables (`FDIDMap.lua`, `CaveData.lua`) into `src/addon/client/`.

Everything else (`docs/`, `assets/`, `.github/`) is repository machinery and is not packaged.

The addons themselves are not a traditional "build" in the sense of compiling a binary. The real work is:

1. fetching Ace3 libraries for local dev
2. generating the map data from minimap tiles and DB2/ADT metadata
3. packaging the two addons for release

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

To load the addons in the game, the client needs a folder named after each
addon with its TOC directly inside it. Link both `src/addon/client/` and
`src/addon/mapdata/` into your AddOns directory under those names:

```sh
ADDONS="<WoW install>/_classic_beta_/Interface/AddOns"
ln -s "$PWD/src/addon/client" "$ADDONS/HighFidelityWorldMap"
ln -s "$PWD/src/addon/mapdata" "$ADDONS/HighFidelityWorldMap_MapData_Forever"
```

The core addon looks for its tiles under
`Interface\AddOns\HighFidelityWorldMap_MapData_Forever\WorldMap\`, so without
the second link the map shows missing textures and the addon prints a warning
in chat at login. `/hfwm debug` reports the Map Data status.

The `X-HFWM-Data-Build` line in the Map Data TOC is empty in the repository. CI
fills it in; locally it stays empty, which the addon treats as a dev build and
skips the "data does not match" check.

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

Tiles are written to `src/addon/mapdata/WorldMap/`; `src/addon/client/FDIDMap.lua` and
`src/addon/client/CaveData.lua` are written into the core addon. Downloads are cached
under `src/generator/.cache-*/`.

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
done < <(grep -E '^[^#[:space:]].*\.(lua|xml)[[:space:]]*$' src/addon/client/HighFidelityWorldMap.toc | tr -d '\r')
```

## 7) CI checks

The repo includes a GitHub Actions workflow that runs linting and smoke-test generation, and dry-runs the packager for both addons (`.pkgmeta` for the core addon, `.pkgmeta-mapdata` for Map Data). This is the same rough validation path contributors should run locally before opening a PR.

## 8) Release packaging

Release packaging is handled by GitHub Actions workflows and the packager tool, not by a local manual compile step.

The two addons are released by two separate workflows with separate tags. They do not trigger each other.

| Workflow | Tags | Ships |
|---|---|---|
| **Create Release: Addon** | `v1.2.3` | `src/addon/client/` (Lua, small). Its generated Lua tables come from the small `maptables-v2-*` cache; the art is never downloaded. |
| **Create Release: MapData** | `mapdata-v1.2.3` | `src/addon/mapdata/` (the art, several GB). The annotated tag body records `art-key: mapart-v2-<hash>`. |

When ready to publish:

- run **Create Release: Addon** (or push a `v*` tag to `main`) to package the addon, create the GitHub release and then start **Publish Release to all Marketplaces** with the new tag. It refuses to package when the generator changed and the Map Data addon has not been released from that build yet: wait for **Create Release: MapData** (or run it), then re-run the failed jobs.
- run **Create Release: MapData** to regenerate (or restore) the art, tag `mapdata-v*`, package `HighFidelityWorldMap_MapData_Forever`, create the GitHub release and publish it. It also runs by itself on a push to `main` that changes the generator and alters the art: those releases are stable and go straight to CurseForge, so release the addon right after. Manual runs take a bump and an optional prerelease suffix (for example `beta.1`).
- run **Publish Release to all Marketplaces** yourself with a release's tag (`v*` or `mapdata-v*`) to retry or redo that upload to CurseForge (and any marketplaces added later)
- **Publish Release to CurseForge** does the CurseForge step on its own if you only need that one; the tag decides which of the two CurseForge projects it uploads to

The generated art and tables are cached under a hash of the generator sources: `mapart-v2-<hash>` for `src/addon/mapdata/WorldMap/` and `maptables-v2-<hash>` for `FDIDMap.lua` and `CaveData.lua`. `FDIDMap.lua` and the Map Data TOC are stamped with the same hash (`HFWMF_DATA_BUILD` and `X-HFWM-Data-Build`), which is how the addon notices a mismatched pair in game.

## Notes

- The generated `src/addon/mapdata/WorldMap/` directory is a build artifact and is not normally committed.
- `src/addon/client/FDIDMap.lua` and `src/addon/client/CaveData.lua` are part of the repo and are produced by the generator.
- `src/addon/client/Libs/` is fetched during local dev and CI; none of its contents are committed.
