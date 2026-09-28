"""CaveData.lua generation.

Writes the interior map table built by :mod:`hfwm.microdungeon` out as a
Lua source file the addon loads at startup.

The table stands in for the interior rows this build's ``UiMap`` does not
have, so its shape deliberately mirrors what the C_Map interior APIs
would have returned.  ``Cave.lua`` reads it through the same accessors it
uses for C_Map, which is what lets one renderer serve both sources:

    HFWMF_CAVE_DATA = {
        build   = "1.60.1.69913",
        places  = {
            {
                name    = "Fargodeep Mine",   -- the window's titlebar
                kind    = "micro",            -- or "dungeon"
                mapID   = 0,                  -- Map.ID it sits on
                groupID = 139,                -- 0 when single-floor
                areaIDs = { 57 },             -- union over floors
                bounds  = { minX, maxX, minY, maxY },  -- or nil
                floors  = {                   -- ordered, shallowest first
                    {
                        name    = "Fargodeep Mine",
                        uiMapID = 38,         -- retail's ID, for tracing
                        areaIDs = { 57 },
                        bounds  = { ... },    -- or nil
                        layerW  = 1002, layerH = 668,
                        tileW   = 256,  tileH  = 256,
                        cols    = 4,    rows   = 3,
                        tiles   = { 603267, ... },  -- row-major FileDataIDs
                    },
                    ...
                },
            },
            ...
        },
        byArea = { [57] = { <place>, ... } },  -- built at load
    }

``tiles`` holds Blizzard's own ``FileDataID``s, not bundled texture
paths, and that is the point: this build ships the interior art, it just
has no map table pointing at it.  ``CaveRenderer`` still runs each FDID
through ``FDIDMap`` first, so if a future art pass ever re-cuts interior
art the swap happens with no change here.

``uiMapID`` is retail's numbering, which does not exist on this build —
this client renumbered the world (Elwynn Forest is 1429 here, 37 on
retail).  It is emitted only as a stable key for tracing and for
suppression bookkeeping; nothing passes it to a C_Map function.
"""

from __future__ import annotations

import re
import time

from .constants import CAVE_DATA_FILE, GAME_BUILD


def _mask_comments_and_strings(text: str) -> str:
    """Return *text* with comment and string-literal contents blanked out
    (same length, same newlines), so brace-depth scanning never miscounts
    a stray ``{``/``}`` that only appears in prose or a path string.
    """
    out = list(text)
    i, n = 0, len(text)
    in_comment = False
    in_string = False
    while i < n:
        ch = text[i]
        if in_comment:
            if ch != "\n":
                out[i] = " "
            else:
                in_comment = False
            i += 1
            continue
        if in_string:
            if ch == '"':
                in_string = False
            elif ch == "\\" and i + 1 < n:
                out[i] = " "
                out[i + 1] = " "
                i += 2
                continue
            else:
                out[i] = " "
            i += 1
            continue
        if ch == "-" and i + 1 < n and text[i + 1] == "-":
            in_comment = True
            i += 2
            continue
        if ch == '"':
            in_string = True
            i += 1
            continue
        i += 1
    return "".join(out)


def _extract_preserved_places(existing_text: str) -> dict[str, str]:
    """Pull hand-added cave-satellite-v2 place blocks out of an on-disk
    CaveData.lua, keyed by place ``name``.

    A place carries hand-added data when its block has a place-level
    ``projection`` or ``pieces`` field -- the DB2-driven pass this module
    runs never emits either, so their presence marks a block the
    hfwm-add-cave skill spliced in by hand. Those two fields (see
    hfwm/cave_minimap.py) are exactly what a plain regeneration has no
    way to reconstruct, so this lets the caller restore the whole block
    verbatim instead of quietly reverting the place to its generic
    floors-only entry. Comments and formatting are preserved exactly
    since the block is copied as raw text, not re-serialized.
    """
    masked = _mask_comments_and_strings(existing_text)
    marker = "places = {"
    start = masked.find(marker)
    if start == -1:
        return {}
    body_start = start + len(marker)

    depth = 1
    i = body_start
    n = len(existing_text)
    while i < n and depth > 0:
        c = masked[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
        i += 1
    body_end = i - 1  # index of the matching closing '}' of `places = { ... }`

    body = existing_text[body_start:body_end]
    masked_body = masked[body_start:body_end]

    preserved: dict[str, str] = {}
    depth = 0
    block_start = None
    for j, c in enumerate(masked_body):
        if c == "{":
            depth += 1
            if depth == 1:
                block_start = j
        elif c == "}":
            depth -= 1
            if depth == 0 and block_start is not None:
                block = body[block_start:j + 1]
                if "projection = {" in block or "pieces = {" in block:
                    m = re.search(r'name\s*=\s*"([^"]*)"', block)
                    if m:
                        preserved[m.group(1)] = block
                block_start = None
    return preserved


def _lua_string(value: str) -> str:
    """Quote *value* as a Lua string literal."""
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _lua_int_array(values: list[int]) -> str:
    return "{ " + ", ".join(str(v) for v in values) + " }"


def _lua_num(value: float) -> str:
    """Format a number without a trailing ``.0``, which Lua does not need."""
    if value == int(value):
        return str(int(value))
    return repr(round(value, 2))


def _lua_bounds(bounds: list[float] | None) -> str:
    if not bounds:
        return "nil"
    return "{ " + ", ".join(_lua_num(v) for v in bounds) + " }"


def generate_cave_data(places: list[dict]) -> dict:
    """Write ``CaveData.lua`` from *places* and return a summary dict."""
    floors = sum(len(p["floors"]) for p in places)
    multi = sum(1 for p in places if len(p["floors"]) > 1)
    tiles = sum(len(f["tiles"]) for p in places for f in p["floors"])

    # Read whatever is currently on disk *before* overwriting it, so any
    # hand-added cave-satellite-v2 place blocks (projection/pieces --
    # this DB2-driven pass only ever emits the generic floors-only shape)
    # can be restored verbatim rather than silently reverted. See
    # hfwm-add-cave's landmine warning and SYNTHETIC_FDID_BASE's comment.
    preserved: dict[str, str] = {}
    if CAVE_DATA_FILE.is_file():
        try:
            preserved = _extract_preserved_places(
                CAVE_DATA_FILE.read_text(encoding="utf-8")
            )
        except OSError:
            preserved = {}

    seen: set[str] = set()
    with open(CAVE_DATA_FILE, "w", encoding="utf-8") as handle:
        _write_header(handle, places, floors, multi, tiles)
        handle.write("HFWMF_CAVE_DATA = {\n")
        handle.write(f"    build = {_lua_string(GAME_BUILD)},\n")
        handle.write("    places = {\n")
        for place in places:
            name = place["name"]
            if name in preserved:
                handle.write("        " + preserved[name] + ",\n")
                seen.add(name)
            else:
                _write_place(handle, place)
        # Anything hand-added that this pass's fresh output no longer
        # produces (renamed or removed upstream) is kept rather than
        # dropped -- restoring lost art silently is exactly the failure
        # mode this guard exists to prevent.
        leftover = [name for name in preserved if name not in seen]
        for name in leftover:
            handle.write("        " + preserved[name] + ",\n")
        handle.write("    },\n")
        handle.write("}\n")

    print(
        f"  Generated CaveData.lua: {len(places)} interiors, {floors} "
        f"floors ({multi} multi-level), {tiles} tiles.",
        flush=True,
    )
    if preserved:
        print(
            f"  Preserved {len(preserved)} hand-added cave-satellite-v2 "
            f"place(s): {', '.join(sorted(preserved))}.",
            flush=True,
        )
    if leftover:
        print(
            f"  WARNING: {len(leftover)} preserved place(s) were not in "
            f"this pass's fresh output (kept anyway): "
            f"{', '.join(leftover)}.",
            flush=True,
        )
    return {
        "places": len(places),
        "floors": floors,
        "multi": multi,
        "tiles": tiles,
        "preserved": len(preserved),
    }


def _write_header(
    handle,
    places: list[dict],
    floors: int,
    multi: int,
    tiles: int,
) -> None:
    micro = sum(1 for p in places if p["kind"] == "micro")
    dungeon = len(places) - micro
    handle.write("-- Auto-generated by generateHFWM.py - DO NOT EDIT\n")
    handle.write(
        f"-- {len(places)} interiors ({micro} micro, {dungeon} dungeon), "
        f"{floors} floors, {multi} multi-level, {tiles} tiles\n"
    )
    handle.write(f"-- Build: {GAME_BUILD}\n")
    handle.write(f"-- Generated: {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    handle.write("--\n")
    handle.write("-- This build's UiMap table has no Dungeon or Micro rows, so\n")
    handle.write("-- C_Map cannot name a cave, describe its art or group its\n")
    handle.write("-- floors. The art itself does ship. This table is the\n")
    handle.write("-- missing map plumbing, rebuilt offline and validated\n")
    handle.write("-- against this build: see hfwm/microdungeon.py.\n")
    handle.write("--\n")
    handle.write("-- areaIDs are this build's own AreaTable IDs. The addon\n")
    handle.write("-- compares C_Map.GetAreaInfo(id) with GetSubZoneText(), so\n")
    handle.write("-- both sides come from the client's locale and the match\n")
    handle.write("-- holds in every language despite this file being built\n")
    handle.write("-- from enUS exports.\n")
    handle.write("--\n")
    handle.write("-- bounds are world-space { minX, maxX, minY, maxY } and may\n")
    handle.write("-- be nil. They are a secondary check only: the source rows\n")
    handle.write("-- carry no usable Z bounds, so a rectangle test alone also\n")
    handle.write("-- matches the hillside above a mine.\n")


def _write_place(handle, place: dict) -> None:
    handle.write("        {\n")
    handle.write(f"            name    = {_lua_string(place['name'])},\n")
    handle.write(f"            kind    = {_lua_string(place['kind'])},\n")
    handle.write(f"            mapID   = {place['mapID']},\n")
    handle.write(f"            groupID = {place['groupID']},\n")
    handle.write(
        f"            areaIDs = {_lua_int_array(place['areaIDs'])},\n"
    )
    handle.write(
        f"            bounds  = {_lua_bounds(place.get('bounds'))},\n"
    )
    handle.write("            floors  = {\n")
    for floor in place["floors"]:
        _write_floor(handle, floor)
    handle.write("            },\n")
    handle.write("        },\n")


def _write_floor(handle, floor: dict) -> None:
    handle.write("                {\n")
    handle.write(
        f"                    name    = {_lua_string(floor['name'])},\n"
    )
    handle.write(f"                    uiMapID = {floor['uiMapID']},\n")
    handle.write(
        f"                    areaIDs = {_lua_int_array(floor['areaIDs'])},\n"
    )
    handle.write(
        f"                    bounds  = {_lua_bounds(floor.get('bounds'))},\n"
    )
    handle.write(
        f"                    layerW  = {floor['layerW']}, "
        f"layerH = {floor['layerH']},\n"
    )
    handle.write(
        f"                    tileW   = {floor['tileW']}, "
        f"tileH  = {floor['tileH']},\n"
    )
    handle.write(
        f"                    cols    = {floor['cols']}, "
        f"rows   = {floor['rows']},\n"
    )
    handle.write("                    tiles   = {\n")
    # Row-major, laid out one grid row per source line so a wrong tile is
    # findable by eye against the map it draws.
    cols = floor["cols"]
    for start in range(0, len(floor["tiles"]), cols):
        row = floor["tiles"][start:start + cols]
        handle.write(
            "                        "
            + ", ".join(str(t) for t in row) + ",\n"
        )
    handle.write("                    },\n")
    handle.write("                },\n")
