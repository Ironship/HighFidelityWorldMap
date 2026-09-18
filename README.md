# High Fidelity World Map: Forever

A fork of [HighFidelityWorldMap](https://github.com/Sectimus/HighFidelityWorldMap) pinned to the
**World of Warcraft Forever** beta client (`wow_classic_beta`, build `1.60.1.69913`).

It replaces the world map's hand-painted art with a satellite-style view stitched from the game's
own minimap terrain tiles, drawn inside Blizzard's native map framework rather than replacing it.

Type `/hfwmf` in game to toggle.

## Layout

Two halves, no server component.

- **Lua addon** (12 files, load order defined in the `.toc` and load-bearing) — hooks
  `WorldMapFrame`, hides Blizzard's detail-layer art and exploration pins, and draws the bundled
  tiles from a texture pool. `Renderer.lua` is the core.
- **Python pipeline** (`generateHFWM.py` → `hfwm/`) — runs offline, produces `WorldMap/` and
  `FDIDMap.lua`.

## Regenerating the map art

`WorldMap/` (60 zones, 687 BLPs, ~177 MB) is a build artifact and is not tracked. Rebuild it with:

```sh
python generateHFWM.py
```

Phases: build the zone DB from wago.tools DB2 exports plus WDT `MAID` chunks → download the
minimap BLPs from CASC → per zone stitch, crop to world bounds, fit the art layer, slice to BLP2 →
emit `FDIDMap.lua`. Useful flags: `--zones`, `--dry-run`, `--refresh`, `--threads`, `--maid-field`.

## How this fork differs from retail

- **No community listfile.** Tile identity comes straight from the build-pinned `UiMapArtTile`
  export, which is authoritative for this build rather than inferred.
- **No `WorldMapArea`.** That table 404s on this build, so zone bounds come from
  `UiMapAssignment.Region_*` (`loc_top=Region_3`, `loc_bottom=Region_0`, `loc_left=Region_4`,
  `loc_right=Region_1`).
- **No AI inpainting, continent overlays or zone presets.** Gaps stay black — the output is an
  honest stitched minimap, warts and all.

## Gotchas

- **Geometry is the critical invariant.** Output must match the client's expected art-layer
  dimensions exactly (e.g. 1002×668 pasted top-left into a 1024×768 grid of 4×3 256px tiles,
  trimmed by `SetTexCoord`). Errors here look like subtle drift and stretching, not obvious
  breakage.
- **`wago.tools/api/casc/{fdid}` is not product-pinned.** It serves whichever build was most
  recently ingested, so FDID-keyed caches must never be shared between products. Hence the
  build-stamped `.cache-{product}-{build}/` directory and the md5 provenance record it writes.
- **`## Interface: 16001`** is inferred from the `major*10000 + minor*100 + patch` formula used by
  other non-mainline flavors, not confirmed against an authoritative source. If it's wrong the
  addon shows as out of date but still loads with "Load out of date AddOns" enabled.
- **MAID field 5 is `mapTexture`** (terrain LOD diffuse), not a "no liquid" variant. Field 7,
  `minimapTexture`, is the one the pipeline wants.
