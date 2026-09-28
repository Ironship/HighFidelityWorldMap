# High Fidelity World Map: Forever

A fork of [HighFidelityWorldMap](https://github.com/Sectimus/HighFidelityWorldMap) pinned to the
**World of Warcraft Forever** beta client (`wow_classic_beta`, build `1.60.1.69913`).

It replaces the world map's hand-painted art with a satellite-style view stitched from the game's
own minimap terrain tiles, drawn inside Blizzard's native map framework rather than replacing it.

Type `/hfwm` in game to toggle, `/hfwm options` for the settings panel. Built on
[Ace3](https://www.wowace.com/projects/ace3) (AceAddon/AceConsole/AceDB/AceConfig), so the
settings panel supports profiles and lives in the client's own Interface Options / Escape menu.

## Layout

Two halves, no server component.

- **Lua addon** (load order defined in the `.toc` and load-bearing): hooks `WorldMapFrame`,
  hides Blizzard's detail-layer art and exploration pins, and draws the bundled tiles from a
  texture pool. `Renderer.lua` is the core; `Options.lua` is the settings panel. Ace3 libraries
  are fetched at build/dev time rather than committed; see `.pkgmeta` and `dev/fetch-libs.sh`.
- **Python pipeline** (`generateHFWM.py` → `hfwm/`): runs offline, produces `WorldMap/` and
  `FDIDMap.lua`.

## Local development setup

The addon runs on [Ace3](https://www.wowace.com/projects/ace3) (AceAddon, AceConsole, AceDB,
AceConfig, AceGUI). Those libraries aren't committed. `LibStub` and `CallbackHandler-1.0` are
the exception: they're tiny and effectively frozen, so they're committed directly under `Libs/`
instead of fetched.

Two sources feed `Libs/`, for two different jobs:

- **Release builds** (CurseForge, GitHub releases): `.pkgmeta`'s `externals:` pull from the
  canonical WowAce svn trunk, the source Ace3's own docs say a `.pkgmeta` should reference.
  Handled entirely by the packager (`.github/workflows/release.yml`); nothing to do locally.
- **Dev and CI checkouts**: `dev/fetch-libs.sh` pulls the same libraries from
  [WoWUIDev/Ace3](https://github.com/WoWUIDev/Ace3) (the GitHub mirror Ace3's project page
  names as its development repository), so testing from source only needs `git`, not `svn`.

To test the addon from a checkout of this repo (as opposed to a downloaded release zip, which
already has `Libs/` baked in):

1. From the addon's folder, run:
   ```sh
   ./dev/fetch-libs.sh
   ```
   This populates `Libs/AceAddon-3.0`, `Libs/AceConsole-3.0`, etc. (about 8 folders). Re-run it
   any time you want to pick up upstream Ace3 changes.
2. `/reload` or relaunch the client. `embeds.xml` (in the `.toc`) loads everything from `Libs/`
   before the addon's own files.

If `Libs/` is missing or incomplete, the addon won't load at all (Lua errors on `LibStub` or one
of the Ace3 calls in `Namespace.lua`/`Core.lua`), so step 1 above isn't optional for a fresh
checkout. CI runs the same script before linting (see `.github/workflows/ci.yml`), so a broken
or renamed mirror path fails there rather than silently at release time.

## Regenerating the map art

`WorldMap/` (60 zones, 687 BLPs, ~175 MB) is a build artifact and is not tracked. Rebuild it with:

```sh
python generateHFWM.py
```

Phases: build the zone DB from wago.tools DB2 exports plus WDT `MAID` chunks → download the
minimap BLPs from CASC → per zone stitch, apply the art passes, crop to world bounds, fit the art
layer, slice to BLP2 → emit `FDIDMap.lua`. Useful flags: `--zones`, `--dry-run`, `--refresh`,
`--threads`, `--maid-field`, plus the art-pass flags below.

## Art passes

An honest stitch of the game's own minimap tiles is the baseline. Anything that goes beyond that and
changes pixels the player will see is an **art pass**, and the rule is:

> If a pass modifies the art, it is registered in `hfwm/effects.py`. There is no such thing as an
> always-on art transform.

Registering is what makes a pass toggleable. From the registry the CLI derives, with no per-pass
code: a `--<name>` / `--no-<name>` pair defaulting to the pass's own default, a `--<name>-<option>`
flag for each option (parsed and validated by the option itself), a line in the run banner, and a
stamp in the `FDIDMap.lua` header recording which passes produced the installed art — which matters
because `WorldMap/` isn't tracked, so that header is the only committed record of how it was made.

`--list-art-passes` describes what's available; `--no-art-passes` turns the lot off for a raw
stitch. Three exist, and they're alternatives rather than a stack: each *supersedes* the ones before
it, so a pass that is merely on by default loses silently (with a note) and two contradictory
*explicit* requests are an error.

The default is the one that decides least. `alpha-sea` leaves the sea transparent and picks no
backdrop at all, which moves the choice out of the pipeline and into the addon's options panel,
where it costs a dropdown rather than a 175 MB rebuild. `--ocean` and `--base-art` bake a backdrop
into the BLPs instead; both are still worth having, for the reasons in their sections below, but
neither is what a plain `python generateHFWM.py` produces any more.

### `--alpha-sea` (default on)

Same ocean palette as `--ocean` below, opposite conclusion: matching pixels are made **transparent**
instead of recoloured, the stitch canvas starts transparent so uncovered cells stay holes, and no
cell classification is done. `hfwm/blp.py` writes BLP2 as uncompressed BGRA with `alphaDepth = 8`,
so the alpha survives into the shipped file intact — which is the whole reason one set of BLPs can
serve three of the four in-game backgrounds.

The erase clears **only the alpha**, leaving the sea's original colour sitting in the RGB channels
where blending will never show it. That is the better neighbour for the downscale: a coast fringe at
partial alpha then blends land into *sea* rather than into black, which is the classic dark halo.

It is *not* a route to the raw look, though it was built as one. Because the RGB survives, the
shipped files are bit-exact to a `--no-art-passes` build, so drawing them with
`SetBlendMode("DISABLE")` ought to ignore the alpha and put the original pixels back on screen —
two-tone sea, hard cell seams, black voids and all — for no second set of BLPs. It doesn't: this
client honours the alpha channel whatever blend mode a texture is given, and the map came back
see-through. The in-game **Original** background is a genuinely separate dump instead
(`--original`, below), and this pass's remaining justification is the downscale one above.

Keeping it there takes `hfwm/resample.py`. Pillow resizes RGBA in premultiplied space and divides
alpha back out, so any pixel at alpha 0 comes back black — silently undoing the whole thing.
`resize_rgba` resamples the RGB plane and the alpha plane separately instead, and every resize on
this path goes through it: both of `hfwm/zone.py`'s, and `hfwm/blp.py`'s mip chain (only one level
is written today, so that one is insurance against raising `NUM_MIP_LEVELS` — a mip that had zeroed
the sea would fringe the coastline as the map zooms). The final flatten is a plain `paste` rather than
`alpha_composite` for the same reason: compositing resolves transparent pixels against the canvas
and throws the colour away.

Verified per zone by `work/verify_install.py`, which stitches each shipped BLP, ignores its alpha
and diffs against a `--no-art-passes` build of the same zone: 13 zones, max delta 0.

The trade-off against `--ocean` is the cell classification it gives up: a flat backdrop drawn at
runtime cannot tell an empty cell that opens onto the sea from one walled inside a landmass, so on
the Ocean Blue background the ~1% of cells `--ocean` deliberately leaves black (60 of 7719 in a full
build, all interior voids) go blue instead.

### `--ocean` (default off)

The raw stitch renders the sea three different ways, which meet as hard rectangular seams on
533-yard tile boundaries: an ADT with no terrain bakes a near-black `(8,16,16)` fill, an ADT that
does have terrain renders its water through the water shader as a lighter `(26,50,69)`, and cells
the WDT has no tile for at all are simply absent (74% of the Eastern Kingdoms art layer).
`hfwm/ocean.py` collapses all three onto one colour in two passes:

- **Pixel pass** — every pixel matching the measured ocean palette (`OCEAN_FILL_COLORS`, ±10 per
  channel) is recoloured. This runs at each tile's native resolution *before* the downscale to the
  region's stitch resolution; do it after and the downscale has already blended dark ocean into
  light across every coast tile. Inland lakes carry their own tint, are not in the palette, and
  survive.
- **Cell pass** — empty cells are grouped into 4-connected components over the region's WDT grid,
  and a component is filled only if it borders a tile that is at least 50% ocean. So the sea around
  a continent or island fills, while an interior map's baked grey void (Alterac Valley) or a hole in
  the middle of a landmass stays black.

The art layer is then flattened onto the ocean colour rather than black, so the uncovered
background — the rightmost ~6% of the Eastern Kingdoms layer, whose world bounds run past the
terrain grid — matches the sea too.

`--ocean-color` picks the target colour (default `#1A3245`, the game's own coastal water: unify onto
the near-black open-ocean fill instead and every shore gets darker rather than the sea getting
consistent).

Baking the colour in is only worth it for that cell pass — the Ocean Blue background in game gets
the same flat sea without it.

### `--base-art` (default off)

Rather than choosing a colour for everything the stitch doesn't cover, use the client's own art
layer as the backdrop, so Blizzard's hand-painted ocean, coastline, parchment border and map labels
come back with the satellite terrain drawn over the top. The Hybrid background in game gets the same
look at runtime, by leaving the client's own detail layer visible under transparent tiles, so this
pass is for baking that look into the files rather than for seeing it.

It erases the sea exactly as `alpha-sea` does; the only difference is that something is composited
underneath before the BLPs are written. The backdrop is rebuilt from each zone's original art BLPs,
fetched from CASC using the very FDIDs the addon remaps; `tile_fdids` is already in the output grid's
row-major order, so tile *i* of the original lands exactly where tile *i* of ours goes. They're
cached separately under `.cache-{product}-{build}/baseart/`.

Zones whose original art is itself blank (the unfinished `ZephrasIsle`) gain only the border, and an
interior map that bakes its own grey void into its minimap tiles (`AlteracValley`) still covers most
of the frame — the pass can only reveal what Blizzard actually painted.

### `--original` (default on, not a pass)

Phase 3b: the whole of phase 3 again with `passes={}`, written to `WorldMap/Original/<Zone>/`. Not
registered in `ART_PASSES`, because it isn't a transform — it's a *second output*, and it produces
the art behind the in-game **Original** background.

It has to be a real second dump. The shipped BLPs are bit-exact to a raw stitch in their RGB
channels, so forcing their alpha to 255 would be a valid derivation — but only while `alpha-sea` is
the enabled pass, which would mean two code paths for one output. Re-running the stitch with every
pass off is correct whatever the primary passes are, and the FDIDs line up tile for tile with the
main table, so the addon swaps between the two without re-laying anything out.

The cost is ~175 MB more on disk and roughly double the phase-3 time; `--no-original` skips it. It's
also skipped automatically under `--no-art-passes`, since the primary output already *is* the raw
stitch and a byte-identical copy would buy nothing. `FDIDMap.lua` gets a second table,
`HFWMF_FDID_MAP_ORIGINAL`, whose paths carry their own `Original\\` prefix so `FDID_BASE` is
unchanged; it's written empty when the tree is absent, which is exactly how the addon knows to leave
the entry out of its dropdown. Phase 4 scans the tree whenever one is on disk rather than only when
this run wrote it, so a rebuild with `--no-original` doesn't silently strip a background whose art is
still installed.

### Adding a pass

Append a `Pass` to `ART_PASSES` in `hfwm/effects.py` and read its settings in `hfwm/zone.py`.
Nothing in `hfwm/cli.py` needs to change. Order in the list is load-bearing: a pass that can lose
has to be listed before its superseder, or a loser could be knocked out by a pass that is itself
knocked out a moment later.

## In game

`/hfwm options` opens the settings panel, built as an AceConfig-3.0 options table
(`Options.lua`). AceConfigDialog registers it into the client's own AddOns options list where
that API exists, and it's openable as a standalone window either way. It carries the enable
toggle, the map background dropdown, the overlay opacity slider, the cave map section, and a
profiles tab (AceDBOptions-3.0) for splitting off a character-specific profile.

### Map background

Because the bundled art ships with a transparent sea (`alpha-sea` above), what sits behind the
terrain is a runtime decision, and every option costs nothing but a redraw:

| Option | What it draws |
| --- | --- |
| **Ocean Blue** | One flat `#1A3245` sea, measured from the game's own water. *(default)* |
| **Hybrid** | No backdrop of ours — Blizzard's hand-painted ocean, coast and parchment border left visible underneath. |
| **Original** | The raw stitch in all its ugly glory — the sea exactly as the game's own tiles render it, two colours, blocky seams and black voids. |
| **Transparent** | No backdrop at all, and the map frame's own backing hidden too — the sea is a hole straight through the UI, onto the 3D world behind it. |

`/hfwm bg NAME` sets it from a macro or keybind; with no name it cycles, which is what a keybind
wants. The entries live in `Config.BACKGROUNDS`, and each answers two independent questions. *What
goes behind the tiles*: an `rgb` triple for a flat backdrop, `blizzardArt = true` to leave the
client's own detail layer showing, or neither for nothing at all — plus `seeThrough = true` to go
one layer further and fade the frame's own backing as well. *Which tiles to draw*: `tiles =
"original"` for the raw dump's own lookup table, or the field omitted for the bundled transparent
art. Only Original sets both — it draws different tiles *and* wants nothing behind them.

**Transparent needs `seeThrough`, or it isn't a choice.** "Nothing behind the tiles" on its own only
reaches as far as Blizzard's map art; one layer below that the frame paints its own panel backing,
and when maximised it covers the world with a blackout frame. Leave those and the sea is a hole onto
a flat panel — identical to Hybrid but for whether the hand-painted art shows, which is not worth a
dropdown entry. `MapFrameBg.lua` hides them, and only for this entry: the other three all put
something opaque in front of the backing, so hiding it would change nothing they draw but could
still show at the map's edges.

It finds them by *draw layer and size*, never by frame name: the names differ between the windowed
and the maximised map and between client builds, and a name that is merely absent fails silently.
Two passes. The first takes every `BACKGROUND`-layer texture on the frames that make up the map's
own panel — the frame, its border frame and inset, their nine-slices, the scroll container and the
canvas — plus the `Bg` and `Center` those templates attach, which are not guaranteed to sit on
`BACKGROUND`. The second sweeps the rest of the chrome tree for any `BACKGROUND` texture covering at
least 70% of the map frame in *both* dimensions, wherever it turns out to live; that is what catches
a backing the first pass has never heard of, and the size gate is what stops it swallowing the small
`BACKGROUND` textures behind buttons, tabs and side panels — the tall ones are narrow and the wide
ones are short. Border art sits on `BORDER` and `OVERLAY` and is left alone either way, so the frame
keeps its edges and title. Only `BlackoutFrame` is taken as a whole frame; everything else is a
texture.

**Concealment is `Hide()`, not alpha 0.** Alpha was the first attempt, on the theory that the client
owns these regions' shown state and re-`Show`s them on open, map change and maximise — so a
Show/Hide fight would be a losing race, while alpha it leaves alone. The second half of that turned
out to be false: the panel templates re-assert alpha along with shown state, so an alpha-0 backing
came back opaque and Transparent ended up indistinguishable from Hybrid. `Hide()` is the stronger
claim, and the one thing that does undo it — `Show`, and `SetShown`, which is a separate C entry
point that does not run the `Show` hook — is hooked on every region touched. Restore re-`Show`s only
what the module actually hid, tracked per region: capturing the client's shown state up front and
replaying it later would get `BlackoutFrame` wrong, since it is hidden while windowed and a state
captured then would leave the world visible through a maximised map.

That search is a hypothesis, though, and `/hfwm framebg` can only report what it already reaches —
useless if the culprit is somewhere it never looks. So there are two diagnostics behind it.
`framebg all` walks the whole frame tree under `WorldMapFrame`, excluding the addon's own widgets,
and prints every texture with its owner, draw layer, sublevel, alpha and texture path, flagging
which rows the targeted search reaches. `framebg nuke` then hides all of it, with `framebg restore`
to undo — not a setting but a bisection: if nuking makes the map see-through, the backing is one of
the surveyed rows and the search can be taught to find it; if it does not, whatever is showing is
not a UI layer at all.

**Original is the only entry that can be missing.** It needs the `--original` dump, which a build
without it never wrote, so `Config:BackgroundAvailable` filters it out of all three dropdown
flavours, `/hfwm bg` refuses it with a note about rebuilding, and the help text and panel hint both
derive their key lists from `Config:AvailableBackgrounds()` so neither can advertise it. A saved
setting of `default` from an earlier version migrates to `transparent` in `Config:InitDB`.

Everything is drawn with ordinary `BLEND`, so the opacity slider applies to all four. An earlier
version drew Original's predecessor with `SetBlendMode("DISABLE")` and had to grey the slider out;
that never worked in game (see `--alpha-sea` above) and the plumbing is gone.

The background selector is an ordinary AceConfig `select` control; AceGUI-3.0 draws it the same
way on every client flavour, so `Options.lua` no longer has to probe which dropdown template a
given client ships.

Two implementation notes, both non-obvious:

- **`BaseArt.visible` is the remembered intent.** The client re-`Show`s and re-tiles its detail
  layers behind the addon's back, so the hooks have to re-assert the choice afterwards — and they
  can't key off `Config.overlayActive` alone, because Hybrid wants the overlay active *and*
  Blizzard's art visible. Gating on `overlayActive and not BaseArt.visible` is what makes that
  combination expressible.
  `MapFrameBg` keeps its own `visible` flag for the same reason and hooks the same way.
- **`BaseArt` finds the detail layers by duck type, not through the pool.** It used to reach them
  only via `WorldMapFrame.detailLayerPool`, with an early `return` when that field was missing — so
  on a client that keeps its detail layers anywhere else, hiding Blizzard's art was a silent no-op.
  Ocean Blue and Original hid the bug perfectly, because both put something opaque on the overlay
  frame *in front* of the detail layer, and the overlay sits 500 frame levels above the canvas.
  Transparent is the only entry with nothing in front, so the symptom was "Transparent looks
  identical to Hybrid" — the parchment, the sea labels and the compass rose all still showing
  through. Any frame under the canvas with a `RefreshDetailTiles` method is now taken as a detail
  layer, whatever the pool is called and whether or not one exists; the pool is one source among
  several rather than the only one. `/hfwm baseart` prints what the search finds, and `/hfwm debug`
  reports the count next to the pool's own state, so an empty search can no longer pass for success.
  Concealment is `Hide()` here too, for the same reason as `MapFrameBg`, with `Show`, `SetShown` and
  `RefreshDetailTiles` all hooked to re-assert it.
- **The background only applies where the addon draws its own tiles.** On a map with no bundled
  BLPs the tiles are the client's own opaque art, so `Renderer` behaves exactly as it did before:
  detail layer hidden, no backdrop, frame backing left alone even under Transparent.

### Cave map

Walk into a cave, a mine, a vault or a cellar and the world map carries on showing the zone above,
which has nothing to say about where you now are — the client gives these places their own UiMapID
but no way to navigate to one from the map. **Cave map** puts them in a small panel over the top of
the map instead: the area's name in a titlebar, a close button, the cave's art at its own aspect
ratio, your own position as an arrow, and a notched vertical depth slider down the right-hand side
when the place has more than one floor.

Off by default, because it draws a panel over the map unprompted and that is not a thing to do to
somebody without being asked. `/hfwm cave` toggles it; `on`, `off`, `show`, `hide`, `reset` and
`alpha N` are all accepted, and the panel has a checkbox and an opacity slider of its own. Opacity
is floored at 20% — a cave map faded to nothing is indistinguishable from the feature being broken,
and there is a close button for the case where it genuinely is not wanted.

Nothing is built until the first cave is entered, so an install that never turns it on pays nothing
for it.

**What it is parented to is the whole design.** `WorldMapFrame`, not
`WorldMapFrame.ScrollContainer.Child` — the canvas. On the canvas it would pan and zoom with the
terrain under it, which is wrong for a window; on the map frame it holds still, and it hides and
shows with the map for free rather than needing a visibility hook. It takes the map's *own* strata
rather than a fixed one, so it rides along when the client moves the map between strata for
windowed and maximised, with a large frame-level offset to clear the map's children. Dragging it is
allowed, and `StartMoving` re-anchors a frame to the screen rather than to its parent — so the
saved position records *which* anchor it used and restores against the same one, or a dragged window
teleports on the next login.

Size is a fraction of the map frame, so it looks the same whether the map is windowed or maximised
on a 4K display, with a legibility floor of 200px and a ceiling that only bites on an ultrawide.
The shape comes from the cave art's own proportions, not the canvas's.

#### When each piece appears

This is the part that is easy to get subtly wrong, so each trigger is stated rather than implied.

- **The window opens** when the map the player is standing on is a `Dungeon` or `Micro` map *and*
  the world map is showing somewhere else. `Orphan` maps are excluded on purpose: having no parent
  in the map hierarchy is a statement about map plumbing rather than about being indoors, and the
  few that exist on this build are transport and scenario scaffolding.
- **"Somewhere else" is compared by map group, not by map ID.** A dungeon's floors are separate
  UiMapIDs, but a world map showing any one of them draws the client's own floor selector — so a
  second set of floor controls on top would duplicate a control that is already right there. Both
  the exact-match and the sibling-floor cases therefore keep the window shut.
- **Where the player is comes from two APIs, not one.** `C_Map.GetBestMapForUnit` resolves the
  player's *position* to a map, and a micro dungeon has its own coordinate space that the position
  only lands in once you are properly inside — on the threshold it still says "the zone".
  `C_Minimap.GetUiMapID` reports the map the *minimap* has swapped its art to, which is the client
  stating that it now considers you inside, driven by the map's bounds rather than by a position
  lookup, and on the way in it is usually first. Neither is reliably ahead, so an interior answer
  from either is taken, with the position lookup winning the tie. Trusting position alone leaves the
  window a beat behind the minimap the player is already looking at. `IsOutdoors()` is deliberately
  *not* consulted — it is true in a great many interiors with no map of their own, every inn and
  every tower, and false in some caves, so as a gate it would both fire spuriously and miss.
- **The art layer is always layer 1.** `C_Map.GetMapArtLayers` can return several, and the extra
  ones are *zoom detail* levels — the same map extent re-cut at higher tile resolution, each
  carrying the canvas scale range it applies to, which the world map swaps between as it zooms.
  This panel does not zoom, so a detail layer would cost several times the textures to draw the
  same picture at a size that cannot show the difference. `Renderer.lua`'s `IsSubmerged()` swap to
  layer 2 is a *different* mechanism — Vashj'ir's paired surface and underwater art, Cataclysm-only
  and so `Config.VASHJIR_MAPS` is empty here — and keying the cave window off it only ever picked a
  detail layer by accident. The layer is chosen in one function so the shape of the box and the
  tiles that go in it can never come from different layers, which is what stretched the art when
  the two were cut to different proportions.
- **The depth slider appears only above one floor**, built from `C_Map.GetMapGroupID` and
  `GetMapGroupMembersInfo` and sorted by `relativeHeightIndex` descending, so the top notch is the
  top floor. Notches are textures *under* the thumb, not clickable frames over it: the thumb always
  snaps to a notch, so a hit-frame would sit on top of the thumb and swallow the mousedown that
  starts a drag. Floors are chosen by dragging the thumb, clicking the track, or the mouse wheel
  anywhere over the window, and the slider's tooltip lists every floor with the active one marked.
- **The player arrow draws only on the floor the player is physically on.** An arrow on every floor
  while you browse the slider would be a lie. It also hides on a `(0, 0)` position, which is the
  API's way of saying it has no fix in that map's space.
- **A floor you picked stays picked** while you are still in the same place — floor follow-along is
  the default, but browsing the level below you is the whole reason the slider is there, so the
  half-second poll does not yank you back. Selecting the floor you are actually standing on hands
  control back to the poll.
- **A cave you closed stays closed until you leave it.** Re-opening on the next poll would make the
  close button useless. The suppression is keyed on the map group, so walking between floors of a
  dungeon you dismissed does not bring it back, and walking out and back in is a clean slate.
  `/hfwm cave show` overrides it.

Cave and dungeon art is not in the bundled tile set — the pipeline stitches outdoor zones — so in
practice every FDID lookup misses and the client's own art is drawn. The lookup is done anyway, so
that a future art pass covering interiors needs no change in `CaveRenderer`. When a cave has no art
at all the footer says so rather than showing an empty box.

## How this fork differs from retail

- **No community listfile.** Tile identity comes straight from the build-pinned `UiMapArtTile`
  export, which is authoritative for this build rather than inferred.
- **No `WorldMapArea`.** That table 404s on this build, so zone bounds come from
  `UiMapAssignment.Region_*` (`loc_top=Region_3`, `loc_bottom=Region_0`, `loc_left=Region_4`,
  `loc_right=Region_1`).
- **No AI inpainting, continent overlays or zone presets.** Nothing is invented. Gaps are filled
  only by an art pass, each of which can be switched off, and every one that exists uses pixels the
  client itself rendered — a colour measured from its own water, or its own art layer underneath —
  or, in the default pass, fills nothing at all and leaves the gap transparent.

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
