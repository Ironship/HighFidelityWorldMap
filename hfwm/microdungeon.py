"""Interior (cave / mine / dungeon) map table builder.

Why this module exists
----------------------
The client can draw a cave.  Walk into Fargodeep Mine and the minimap
fills with tunnels, because the engine has baked minimap art for every
group of the ``md_goldmine`` WMO the mine is built from
(``world/minimaps/wmo/dungeon/md_goldmine/md_goldmine_000_00_00.blp``
and its siblings).  That art is engine-side and not reachable from Lua,
but it is proof the data is there.

And the *world map* art is there too, in a form an addon can use.  This
build ships ``Interface\\WorldMap\\MicroDungeon\\Elwynn\\FargodeepMine\\
FargodeepMine1_1`` through ``..._12`` and a second twelve for the lower
level — the same 1002x668 / 256px-tile 4x3 art layer geometry the
outdoor zones use.  Forty-nine micro-dungeons and sixty-eight dungeon
floors' worth of it, verified present on this exact build.

What is missing is only the *map table*.  This build's ``UiMap`` has 60
rows — one World, four Continent, fifty-five Zone — and no Dungeon or
Micro entry at all.  Without those rows:

  * ``C_Map.GetBestMapForUnit("player")`` keeps returning the outdoor
    zone when the player is underground, because there is no interior
    map for it to return;
  * ``C_Map.GetMapArtLayers`` / ``GetMapArtLayerTextures`` have nothing
    to describe, so the art cannot be looked up; and
  * ``C_Map.GetMapGroupID`` has no groups, so floors do not exist.

So the cave window in Cave.lua / CaveRenderer.lua, which is written
against those APIs and is correct on a client that has them, can never
fire here.

This pass closes that gap offline.  It borrows the interior *plumbing*
from retail's DB2 exports — which floors a place has, in what order,
which tiles draw each one, which area the player must be standing in —
and pins the *art* to this build.  The result is baked into CaveData.lua
and the addon drives its own cave window from that, needing no C_Map
interior support whatsoever.

Nothing is taken on trust.  A retail row survives into the output only
if all of the following hold on the pinned build:

  1. the interior's assignment ``MapID`` is a ``Map`` row this build has;
  2. its layer-0 tile ``FileDataID``\\s resolve on this build's CASC
     (probed through the *pinned* endpoint, so a retail-only file 404s
     rather than quietly answering 200); and
  3. its name — the map name, or the floor name from
     ``UiMapGroupMember`` — matches an ``AreaTable`` row on this build
     whose ``ContinentID`` is that same ``MapID``.

Condition 3 does double duty.  It is the validation that this build
knows the place at all, and it is how the addon recognises the player is
inside one: the emitted table carries ``AreaTable`` IDs, and at runtime
the addon compares ``C_Map.GetAreaInfo(id)`` against
``GetSubZoneText()``.  Both sides come from the client's own locale
data, so the match works in every locale even though this pass reads
enUS exports.

The world-space rectangle from ``UiMapAssignment`` is emitted too, as a
secondary check, but it cannot be the primary one: the ``Region_2`` /
``Region_5`` Z bounds on these rows are -10000 and 1000000, i.e. no
vertical bound at all, so a rectangle test alone fires while the player
is standing on the hillside *above* a mine.
"""

from __future__ import annotations

import csv
import io
from concurrent.futures import ThreadPoolExecutor
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from .cache import CachedFile
from .constants import (
    DB2_CACHE_TTL_DAYS,
    DB2_CACHE_DIR,
    DONOR_DB2_CACHE_DIR,
    DONOR_DB2_CACHE_TTL_DAYS,
    DONOR_DB2_TABLES,
    GAME_BUILD,
    INTERIOR_BUILD_DB2_TABLES,
    INTERIOR_PRESENCE_CACHE,
    INTERIOR_PRESENCE_CACHE_TTL_DAYS,
    INTERIOR_PROBE_WORKERS,
    UI_MAP_TYPE_DUNGEON,
    UI_MAP_TYPE_MICRO,
    USER_AGENT,
    WAGO_CASC_PINNED_FMT,
    db2_url,
    donor_db2_url,
)
from .http import fetch_url

INTERIOR_TYPES = (str(UI_MAP_TYPE_DUNGEON), str(UI_MAP_TYPE_MICRO))

KIND_BY_TYPE = {
    str(UI_MAP_TYPE_DUNGEON): "dungeon",
    str(UI_MAP_TYPE_MICRO): "micro",
}


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def build_cave_table(
    force_refresh: bool = False,
    verbose: bool = True,
) -> list[dict]:
    """Return the interior map table for the pinned build.

    One entry per *place* (a mine, a dungeon), each carrying an ordered
    list of floors.  See the module docstring for what is validated.
    """
    donor = {
        table: _fetch_donor_table(table, force_refresh)
        for table in DONOR_DB2_TABLES
    }
    pinned = {
        table: _fetch_pinned_table(table, force_refresh)
        for table in ("Map", *INTERIOR_BUILD_DB2_TABLES)
    }

    candidates = _collect_candidates(donor, pinned)
    if verbose:
        print(
            f"  {len(candidates)} interior maps on retail sit on a Map this "
            f"build has.",
            flush=True,
        )

    present = _filter_to_present_art(candidates, force_refresh, verbose)
    if verbose:
        print(
            f"  {len(present)} of them have art on {GAME_BUILD}.",
            flush=True,
        )

    located = _attach_areas(present, pinned["AreaTable"])
    if verbose:
        dropped = len(present) - len(located)
        print(
            f"  {len(located)} matched an AreaTable row on this build"
            + (f" ({dropped} dropped — this build does not name them)."
               if dropped else "."),
            flush=True,
        )

    table = _group_into_places(located)
    if verbose:
        floors = sum(len(p["floors"]) for p in table)
        multi = sum(1 for p in table if len(p["floors"]) > 1)
        print(
            f"  {len(table)} interiors, {floors} floors "
            f"({multi} with a depth slider).",
            flush=True,
        )
    return table


# ---------------------------------------------------------------------------
# DB2 downloads
# ---------------------------------------------------------------------------

def _fetch_csv_cached(url: str, cache: CachedFile) -> list[dict]:
    rows, _age = cache.load_or_none()
    if rows:
        return rows
    text = fetch_url(url, timeout=300).decode("utf-8", errors="replace")
    rows = list(csv.DictReader(io.StringIO(text)))
    if not rows:
        raise OSError(f"{url} came back empty.")
    cache.save(rows)
    return rows


def _fetch_donor_table(table: str, force_refresh: bool) -> list[dict]:
    """Fetch an *unpinned* (latest retail) DB2 export.

    Retail is the only place the interior rows exist.  Kept in its own
    cache directory so a retail FDID-keyed export can never be mistaken
    for one describing the pinned build.
    """
    cache = CachedFile(
        DONOR_DB2_CACHE_DIR / f"{table}.json", DONOR_DB2_CACHE_TTL_DAYS,
    )
    if force_refresh and cache.path.is_file():
        cache.path.unlink()
    return _fetch_csv_cached(donor_db2_url(table), cache)


def _fetch_pinned_table(table: str, force_refresh: bool) -> list[dict]:
    """Fetch a build-pinned DB2 export, sharing the main db2 cache."""
    cache = CachedFile(DB2_CACHE_DIR / f"{table}.json", DB2_CACHE_TTL_DAYS)
    if force_refresh and cache.path.is_file():
        cache.path.unlink()
    return _fetch_csv_cached(db2_url(table), cache)


# ---------------------------------------------------------------------------
# Candidate selection
# ---------------------------------------------------------------------------

def _lowest_phase_art(rows: list[dict]) -> dict[str, dict]:
    """Map UiMapID -> its lowest-PhaseID UiMapXMapArt row.

    Phased art is a later-expansion concern (a zone redrawn mid-patch);
    for vanilla interiors there is only ever one phase, and taking the
    lowest matches what the client shows with no phase active.
    """
    best: dict[str, dict] = {}
    for row in rows:
        key = row["UiMapID"]
        if key not in best or int(row["PhaseID"]) < int(best[key]["PhaseID"]):
            best[key] = row
    return best


def _collect_candidates(
    donor: dict[str, list[dict]],
    pinned: dict[str, list[dict]],
) -> list[dict]:
    """Interiors that could plausibly exist on this build.

    Filters retail's 1154 interior maps down by the one cheap, offline
    test available: the map they are assigned to must be a ``Map`` row
    this build actually has.  Art presence is probed separately, over
    the network, so it is worth getting this list small first.
    """
    build_map_ids = {row["ID"] for row in pinned["Map"]}

    ui_by_id = {row["ID"]: row for row in donor["UiMap"]}
    art_for_map = _lowest_phase_art(donor["UiMapXMapArt"])
    art_by_id = {row["ID"]: row for row in donor["UiMapArt"]}

    layers_by_style: dict[str, list[dict]] = {}
    for row in donor["UiMapArtStyleLayer"]:
        layers_by_style.setdefault(row["UiMapArtStyleID"], []).append(row)

    tiles_by_art: dict[str, list[dict]] = {}
    for row in donor["UiMapArtTile"]:
        if row["LayerIndex"] != "0":
            continue
        tiles_by_art.setdefault(row["UiMapArtID"], []).append(row)

    assignments: dict[str, list[dict]] = {}
    for row in donor["UiMapAssignment"]:
        assignments.setdefault(row["UiMapID"], []).append(row)

    # Attached here rather than at grouping time because a floor is
    # sometimes named after its own AreaTable row instead of the place's
    # ("Ironclad Cove" inside "The Deadmines"), and _attach_areas needs
    # both names to have a chance of matching.
    members = {row["UiMapID"]: row for row in donor["UiMapGroupMember"]}

    out = []
    for ui_map in donor["UiMap"]:
        if ui_map["Type"] not in INTERIOR_TYPES:
            continue

        assigned = assignments.get(ui_map["ID"])
        if not assigned:
            continue
        on_build = [a for a in assigned if a["MapID"] in build_map_ids]
        if not on_build:
            continue

        art = art_for_map.get(ui_map["ID"])
        if not art:
            continue
        art_row = art_by_id.get(art["UiMapArtID"])
        if not art_row:
            continue

        layers = sorted(
            layers_by_style.get(art_row["UiMapArtStyleID"], []),
            key=lambda row: int(row["LayerIndex"]),
        )
        if not layers:
            continue

        tiles = sorted(
            tiles_by_art.get(art["UiMapArtID"], []),
            key=lambda row: (int(row["RowIndex"]), int(row["ColIndex"])),
        )
        if not tiles:
            continue

        # The client indexes GetMapArtLayerTextures row-major, so the
        # emitted list must be row-major too.  UiMapArtTile is already
        # sorted that way above; this only asserts the grid is complete,
        # because a hole would silently shift every later tile.
        rows = max(int(t["RowIndex"]) for t in tiles) + 1
        cols = max(int(t["ColIndex"]) for t in tiles) + 1
        if rows * cols != len(tiles):
            continue

        layer = layers[0]
        member = members.get(ui_map["ID"])
        out.append({
            "uiMapID": int(ui_map["ID"]),
            "name": ui_map["Name_lang"],
            "floorName": (member and member["Name_lang"]) or "",
            "groupID": int(member["UiMapGroupID"]) if member else 0,
            "floorIndex": int(member["FloorIndex"]) if member else 1,
            "type": ui_map["Type"],
            "kind": KIND_BY_TYPE[ui_map["Type"]],
            "parentUiMapID": int(ui_map["ParentUiMapID"] or 0),
            "mapID": int(on_build[0]["MapID"]),
            "bounds": _world_bounds(on_build),
            "layerW": int(layer["LayerWidth"]),
            "layerH": int(layer["LayerHeight"]),
            "tileW": int(layer["TileWidth"]),
            "tileH": int(layer["TileHeight"]),
            "cols": cols,
            "rows": rows,
            "tiles": [int(t["FileDataID"]) for t in tiles],
        })
    return out


# Some assignment rows carry +/-20000 on both axes, which is not a
# rectangle so much as "wherever the player is" — Deadmines' Ironclad
# Cove is one.  A world span wider than this is treated as absent rather
# than emitted, so the runtime rectangle test cannot be satisfied by a
# row that never meant to constrain anything.  Azeroth itself is about
# 34000 yards across, hence the threshold.
UNBOUNDED_WORLD_SPAN = 30000.0


def _world_bounds(assignments: list[dict]) -> list[float] | None:
    """Union the world-space rectangles of *assignments*.

    Region field convention is the one hfwm/db2.py documents and every
    known zone confirms: world X runs between ``Region_0`` and
    ``Region_3``, world Y between ``Region_1`` and ``Region_4``.  A
    micro-dungeon gets one assignment row per WMO group it spans, so the
    union over them is the footprint of the whole floor.

    ``Region_2`` / ``Region_5`` — the Z bounds — are deliberately not
    returned.  On these rows they are -10000 and 1000000, which bounds
    nothing, so there is no altitude information here to emit.

    Returns ``None`` when the union is too large to mean anything.
    """
    xs: list[float] = []
    ys: list[float] = []
    for row in assignments:
        xs += [float(row["Region_0"]), float(row["Region_3"])]
        ys += [float(row["Region_1"]), float(row["Region_4"])]
    bounds = [round(min(xs), 2), round(max(xs), 2),
              round(min(ys), 2), round(max(ys), 2)]
    if (bounds[1] - bounds[0] > UNBOUNDED_WORLD_SPAN
            or bounds[3] - bounds[2] > UNBOUNDED_WORLD_SPAN):
        return None
    return bounds


# ---------------------------------------------------------------------------
# Art presence on the pinned build
# ---------------------------------------------------------------------------

def _art_present(fdid: int) -> bool:
    """Whether *fdid* resolves on the pinned build.

    Must go through the pinned endpoint.  Unpinned, ``/api/casc/{fdid}``
    serves whichever build was ingested last, so a retail-only file
    answers 200 and would be baked into a table claiming to describe
    this build.
    """
    request = Request(
        WAGO_CASC_PINNED_FMT.format(fdid=fdid),
        headers={"User-Agent": USER_AGENT},
    )
    try:
        with urlopen(request, timeout=30) as response:
            return len(response.read(64)) > 0
    except HTTPError:
        return False
    except OSError:
        return False


def _filter_to_present_art(
    candidates: list[dict],
    force_refresh: bool,
    verbose: bool,
) -> list[dict]:
    """Drop candidates whose art this build does not ship.

    Probes the first tile of each candidate rather than all of them: art
    is shipped per map, so one hit means the set is there.  Results are
    cached because the answer only changes when the build does.
    """
    cache = CachedFile(
        INTERIOR_PRESENCE_CACHE, INTERIOR_PRESENCE_CACHE_TTL_DAYS,
    )
    known: dict[str, bool] = {}
    if not force_refresh:
        cached, _age = cache.load_or_none()
        if isinstance(cached, dict):
            known = cached

    unknown = [c for c in candidates if str(c["tiles"][0]) not in known]
    if unknown:
        if verbose:
            print(
                f"  Probing {len(unknown)} interior art sets against "
                f"{GAME_BUILD}...",
                flush=True,
            )
        with ThreadPoolExecutor(max_workers=INTERIOR_PROBE_WORKERS) as pool:
            results = pool.map(
                lambda c: _art_present(c["tiles"][0]), unknown,
            )
            for candidate, ok in zip(unknown, results):
                known[str(candidate["tiles"][0])] = ok
        cache.save(known)

    return [c for c in candidates if known.get(str(c["tiles"][0]))]


# ---------------------------------------------------------------------------
# AreaTable linkage
# ---------------------------------------------------------------------------

def _attach_areas(
    candidates: list[dict],
    area_table: list[dict],
) -> list[dict]:
    """Attach this build's AreaTable IDs to each candidate.

    This is both the last validation gate and the runtime detection key.
    A candidate survives only if this build's ``AreaTable`` names the
    place, on the same continent the interior is assigned to.

    Matching is on the enUS name, which is safe *here* because both
    sides of the comparison are enUS exports read offline.  What gets
    emitted is the numeric area ID, so the addon compares
    ``C_Map.GetAreaInfo(id)`` against ``GetSubZoneText()`` — two strings
    from the client's own locale — and works in any language.
    """
    by_name: dict[str, list[dict]] = {}
    for row in area_table:
        name = (row.get("AreaName_lang") or "").strip().lower()
        if name:
            by_name.setdefault(name, []).append(row)

    out = []
    for candidate in candidates:
        names = {candidate["name"]}
        if candidate.get("floorName"):
            names.add(candidate["floorName"])

        area_ids: list[int] = []
        for name in names:
            for row in by_name.get(name.strip().lower(), []):
                # Same continent as the interior sits on, so the Fargodeep
                # Mine in Elwynn is never confused with the one on a
                # later-expansion copy of the zone.
                if row["ContinentID"] != str(candidate["mapID"]):
                    continue
                area_id = int(row["ID"])
                if area_id not in area_ids:
                    area_ids.append(area_id)
        if not area_ids:
            continue
        candidate["areaIDs"] = sorted(area_ids)
        out.append(candidate)
    return out


# ---------------------------------------------------------------------------
# Grouping floors into places
# ---------------------------------------------------------------------------

def _group_into_places(candidates: list[dict]) -> list[dict]:
    """Fold per-floor interior maps into one entry per place.

    ``UiMapGroupMember`` is what makes a depth slider possible: it ties
    the floors of one place to a shared ``UiMapGroupID``, gives each a
    ``FloorIndex`` for the order they stack in, and — usefully — names
    each floor separately from the place ("Fargodeep Mine" has floors
    "Fargodeep Mine" and "Lower Mines").  Those three fields were read
    in _collect_candidates; this only folds on them.

    An interior with no group row is a single-floor place and becomes
    its own entry, with the slider suppressed at runtime.
    """
    places: dict[str, dict] = {}
    for candidate in candidates:
        group_id = candidate["groupID"]
        key = f"g{group_id}" if group_id else f"m{candidate['uiMapID']}"

        floor = {
            "uiMapID": candidate["uiMapID"],
            "name": candidate["floorName"] or candidate["name"],
            "floorIndex": candidate["floorIndex"],
            "areaIDs": candidate["areaIDs"],
            "bounds": candidate["bounds"],
            "layerW": candidate["layerW"],
            "layerH": candidate["layerH"],
            "tileW": candidate["tileW"],
            "tileH": candidate["tileH"],
            "cols": candidate["cols"],
            "rows": candidate["rows"],
            "tiles": candidate["tiles"],
        }

        place = places.get(key)
        if place is None:
            places[key] = {
                "key": key,
                "name": candidate["name"],
                "kind": candidate["kind"],
                "mapID": candidate["mapID"],
                "groupID": group_id,
                "floors": [floor],
            }
        else:
            place["floors"].append(floor)

    out = []
    for place in places.values():
        place["floors"].sort(key=lambda f: (f["floorIndex"], f["uiMapID"]))
        # The place's own area set is the union over its floors, so
        # walking in on any level recognises the place; picking the
        # right floor is a separate, narrower test.
        area_ids: list[int] = []
        for floor in place["floors"]:
            for area_id in floor["areaIDs"]:
                if area_id not in area_ids:
                    area_ids.append(area_id)
        place["areaIDs"] = sorted(area_ids)
        place["bounds"] = _union_bounds([f["bounds"] for f in place["floors"]])
        out.append(place)

    out.sort(key=lambda p: (p["kind"], p["name"], p["mapID"]))
    return out


def _union_bounds(rects: list[list[float] | None]) -> list[float] | None:
    """Smallest rectangle containing every rectangle in *rects*.

    ``None`` if any floor is unbounded: a place is only as well located
    as its vaguest floor, and claiming otherwise would let the rectangle
    test pass somewhere the place is not.
    """
    if not rects or any(r is None for r in rects):
        return None
    return [
        round(min(r[0] for r in rects), 2),
        round(max(r[1] for r in rects), 2),
        round(min(r[2] for r in rects), 2),
        round(max(r[3] for r in rects), 2),
    ]
