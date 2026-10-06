"""FDIDMap.lua generation.

The addon works by intercepting the ``FileDataID``s the client hands back
from ``C_Map.GetMapArtLayerTextures`` and swapping in a bundled texture
path instead.  ``FDIDMap.lua`` is that lookup table.

Only the World and Continent maps are covered (see
``hfwm/cli/phases.py``'s ``art_zones``); zone and cave maps are drawn from
the client's own minimap tiles and need no entry here.

Unlike the retail pipeline this is built straight from ``UiMapArtTile``
(via the zone DB), not from a community listfile — the FDIDs are the
authoritative ones for the pinned build, and every entry is verified
against a file that actually exists on disk.

Two tables come out of it.  ``HFWMF_FDID_MAP`` points at the art the
enabled art passes produced, which is what the addon draws by default.
``HFWMF_FDID_MAP_ORIGINAL`` points at the raw second dump under
``WorldMap/Original/`` and is what the in-game "Original" background
draws; it is empty when that dump was not generated, which is how the
addon knows to leave the entry out of its dropdown.

A third pair, ``HFWMF_NATIVE_ZONES`` / ``HFWMF_NATIVE_ZONES_ORIGINAL``,
covers the three maps in ``HIRES_CONTINENT_MAPS`` (Kalimdor, Eastern
Kingdoms, the top-level Azeroth map), which ``hfwm/gamedata/db2.py``'s
``_hires_geometry`` gave a bigger-than-Blizzard's layer to, capped and
flagged ``continent=true``.  Their output grid no longer matches
Blizzard's own FDID count or order 1:1, so they are excluded from the two
FDID tables above and instead keyed by ``UiMapID`` directly, with their own
geometry and a bare path prefix ``Renderer.lua`` appends a tile index to.

Each of those maps gets *two* zone-DB entries (see ``_build_zone_db``): the
plain key (e.g. ``"Kalimdor"``, ``native=None``) is the ordinary,
Blizzard-grid-matching satellite build, so it lands in ``HFWMF_FDID_MAP``;
a second ``"<key>HD"`` entry (e.g. ``"KalimdorHD"``, ``native`` set)
carries the hi-res geometry into ``HFWMF_NATIVE_ZONES``.  Config.lua's
"Increase world map clarity" toggle reads the ``continent`` flag: off, it
hides the HD entry and Renderer.lua falls through to the ordinary
FDID-mapped satellite art — never to Blizzard's own unreplaced map — and
on, it draws the HD entry.
"""

from __future__ import annotations

from pathlib import Path

from ..config.paths import FDID_MAP_FILE, ORIGINAL_SUBDIR
from ..geometry.tile_grid import tile_filenames
from .source import AUTOGEN_NOTICE, generated_stamp


def _collect(
    root: Path,
    zones: dict[str, dict],
    prefix: str = "",
) -> dict:
    """Gather ``(fdid, relative_path)`` pairs for every BLP present in *root*.

    *prefix* is prepended to each path, so the ``Original/`` tree resolves
    against the same ``FDID_BASE`` the addon already has.  Paths use the
    doubled backslash the generated Lua source needs.
    """
    entries: list[tuple[int, str]] = []
    covered: list[str] = []
    missing_files = 0
    partial: list[str] = []

    if not root.is_dir():
        return {
            "entries": entries, "covered": covered,
            "missing": missing_files, "partial": partial,
        }

    for folder in sorted(zones):
        z = zones[folder]
        if z.get("native"):
            # Native zones have their own, bigger output grid that no
            # longer lines up with Blizzard's FDID list 1:1 -- see
            # _collect_native, which covers them instead.
            continue
        fdids = z["tile_fdids"]
        names = tile_filenames(folder, len(fdids))
        zone_dir = root / folder
        if not zone_dir.is_dir():
            continue

        lua_dir = f"{prefix}\\\\{folder}" if prefix else folder
        zone_entries: list[tuple[int, str]] = []
        absent = 0
        for fdid, fname in zip(fdids, names):
            if not (zone_dir / fname).is_file():
                absent += 1
                continue
            zone_entries.append((fdid, f"{lua_dir}\\\\{Path(fname).stem}"))

        if absent:
            missing_files += absent
            partial.append(f"{folder} ({absent}/{len(names)} missing)")
        if zone_entries:
            entries.extend(zone_entries)
            covered.append(folder)

    return {
        "entries": entries, "covered": covered,
        "missing": missing_files, "partial": partial,
    }


def _collect_native(
    root: Path,
    zones: dict[str, dict],
    prefix: str = "",
) -> dict:
    """Gather native-zone geometry for every zone whose BLPs are present.

    Keyed by ``UiMapID`` rather than FDID: native zones draw from the
    pipeline's own tile grid, not from a client-registered art layer, so
    there is no FileDataID to intercept in the first place.
    """
    entries: dict[int, dict] = {}
    covered: list[str] = []
    missing_files = 0
    partial: list[str] = []

    if not root.is_dir():
        return {
            "entries": entries, "covered": covered,
            "missing": missing_files, "partial": partial,
        }

    for folder in sorted(zones):
        z = zones[folder]
        native = z.get("native")
        if not native:
            continue
        count = native["cols"] * native["rows"]
        names = tile_filenames(folder, count)
        zone_dir = root / folder
        if not zone_dir.is_dir():
            continue

        present = sum(1 for n in names if (zone_dir / n).is_file())
        if present == 0:
            continue
        if present < count:
            missing_files += count - present
            partial.append(f"{folder} ({count - present}/{count} missing)")

        lua_dir = f"{prefix}\\\\{folder}" if prefix else folder
        entries[z["ui_map_id"]] = {
            "cols": native["cols"], "rows": native["rows"],
            "tile_w": native["tile_w"], "tile_h": native["tile_h"],
            "layer_w": native["layer_w"], "layer_h": native["layer_h"],
            "path": f"{lua_dir}\\\\{folder.lower()}",
            # Flags the three capped continent maps so Config.lua can gate
            # them behind "Increase world map clarity" (off by default)
            # while every uncapped Type=Zone map keeps shipping unconditionally.
            "continent": bool(native.get("continent")),
        }
        covered.append(folder)

    return {
        "entries": entries, "covered": covered,
        "missing": missing_files, "partial": partial,
    }


def _collect_metadata(
    zones: dict[str, dict],
    prefix: str = "",
) -> dict:
    """Build the FDID map from zone metadata alone, without scanning BLPs.

    This is the fast path used by client-only builds: the Lua table only needs
    the expected tile layout and IDs, not the generated image tree itself.
    """
    entries: list[tuple[int, str]] = []
    covered: list[str] = []

    for folder in sorted(zones):
        z = zones[folder]
        if z.get("native"):
            continue
        fdids = z["tile_fdids"]
        names = tile_filenames(folder, len(fdids))
        lua_dir = f"{prefix}\\\\{folder}" if prefix else folder
        zone_entries = [
            (fdid, f"{lua_dir}\\\\{Path(fname).stem}")
            for fdid, fname in zip(fdids, names)
        ]
        if zone_entries:
            entries.extend(zone_entries)
            covered.append(folder)

    return {"entries": entries, "covered": covered, "missing": 0, "partial": []}


def _collect_native_metadata(
    zones: dict[str, dict],
    prefix: str = "",
) -> dict:
    """Metadata-only version of _collect_native."""
    entries: dict[int, dict] = {}
    covered: list[str] = []

    for folder in sorted(zones):
        z = zones[folder]
        native = z.get("native")
        if not native:
            continue
        count = native["cols"] * native["rows"]
        names = tile_filenames(folder, count)
        lua_dir = f"{prefix}\\\\{folder}" if prefix else folder
        entries[z["ui_map_id"]] = {
            "cols": native["cols"], "rows": native["rows"],
            "tile_w": native["tile_w"], "tile_h": native["tile_h"],
            "layer_w": native["layer_w"], "layer_h": native["layer_h"],
            "path": f"{lua_dir}\\\\{folder.lower()}",
            "continent": bool(native.get("continent")),
        }
        covered.append(folder)

    return {"entries": entries, "covered": covered, "missing": 0, "partial": []}


def generate_fdid_map(
    output_dir: str,
    zones: dict[str, dict],
    art_passes: list[str] | None = None,
    original: bool = False,
    metadata_only: bool = False,
) -> dict:
    """Write ``FDIDMap.lua`` for every zone whose BLPs are present.

    *art_passes* is the stamp from :func:`hfwm.imaging.effects.stamp` — which art
    passes produced the BLPs the main table points at.  It goes in the
    header because ``WorldMap/`` is a build artifact and is not tracked, so
    this file is the only committed record of how the installed art was
    made.

    *original* asks for the ``Original/`` subtree to be scanned into a
    second table as well.  Passing it when that subtree is absent is not an
    error — the table is simply written empty.

    Returns a small summary dict for the caller to report.
    """
    out = Path(output_dir)
    if metadata_only:
        main = _collect_metadata(zones)
        orig = _collect_metadata(zones, ORIGINAL_SUBDIR) if original else None
        native_main = _collect_native_metadata(zones)
        native_orig = (
            _collect_native_metadata(zones, ORIGINAL_SUBDIR) if original else None
        )
    else:
        if not out.is_dir():
            print("  Output directory not found — skipping FDIDMap.lua.",
                  flush=True)
            return {"entries": 0, "zones": 0, "missing": 0,
                    "original_entries": 0, "original_zones": 0,
                    "native_zones": 0, "native_original_zones": 0}

        main = _collect(out, zones)
        orig = (_collect(out / ORIGINAL_SUBDIR, zones, ORIGINAL_SUBDIR)
                if original else None)
        native_main = _collect_native(out, zones)
        native_orig = (
            _collect_native(out / ORIGINAL_SUBDIR, zones, ORIGINAL_SUBDIR)
            if original else None
        )

    _write_table(main, orig, native_main, native_orig, art_passes or [])

    _warn_partial(main, "main", "")
    _warn_partial(orig, f"{ORIGINAL_SUBDIR}/", f"{ORIGINAL_SUBDIR}/")
    _warn_partial(native_main, "native", "native ")
    _warn_partial(
        native_orig, f"native {ORIGINAL_SUBDIR}/", f"native {ORIGINAL_SUBDIR}/ ",
    )

    return {
        "entries": len(main["entries"]),
        "zones": len(main["covered"]),
        "missing": main["missing"],
        "original_entries": len(orig["entries"]) if orig else 0,
        "original_zones": len(orig["covered"]) if orig else 0,
        "native_zones": len(native_main["covered"]),
        "native_original_zones": len(native_orig["covered"]) if native_orig else 0,
    }


def _warn_partial(res: dict | None, name: str, line_prefix: str) -> None:
    """Report zones in *res* (a ``_collect*`` result) with missing BLPs."""
    partial = res["partial"] if res else []
    if not partial:
        return
    print(f"  WARNING: {len(partial)} {name} zone(s) have missing BLPs:",
          flush=True)
    for line in partial[:10]:
        print(f"    {line_prefix}{line}", flush=True)


def _write_entries(f, entries: list[tuple[int, str]]) -> None:
    for fdid, path in entries:
        f.write(f'    [{fdid}] = "{path}",\n')


def _write_native_zones(f, name: str, entries: dict[int, dict]) -> None:
    """Write a ``HFWMF_NATIVE_ZONES``-shaped table keyed by UiMapID."""
    f.write(f"{name} = {{\n")
    for map_id, g in sorted(entries.items()):
        continent = ", continent=true" if g.get("continent") else ""
        f.write(
            f'    [{map_id}] = {{ cols={g["cols"]}, rows={g["rows"]}, '
            f'tileW={g["tile_w"]}, tileH={g["tile_h"]}, '
            f'layerW={g["layer_w"]}, layerH={g["layer_h"]}, '
            f'path="{g["path"]}"{continent} }},\n'
        )
    f.write("}\n")


def _write_table(
    main: dict,
    orig: dict | None,
    native_main: dict,
    native_orig: dict | None,
    art_passes: list[str],
) -> None:
    """Write ``FDIDMap.lua``."""
    with open(FDID_MAP_FILE, "w", encoding="utf-8") as f:
        f.write(AUTOGEN_NOTICE)
        f.write(
            f"-- {len(main['entries'])} textures across "
            f"{len(main['covered'])} zones\n"
        )
        f.write(generated_stamp())
        if art_passes:
            f.write(f"-- Art passes: {', '.join(art_passes)}\n")
        f.write("HFWMF_FDID_MAP = {\n")
        _write_entries(f, main["entries"])
        f.write("}\n")
        f.write("\n-- No submerged (layer-2) art variants are generated for\n")
        f.write("-- this build; kept so Renderer.lua's lookup stays valid.\n")
        f.write("HFWMF_FDID_MAP_SUB = {}\n")

        f.write("\n-- The raw stitch, with no art pass applied: the sea in\n")
        f.write("-- the two colours the game's own tiles render it, hard\n")
        f.write("-- cell seams, black voids and all. A genuinely separate\n")
        f.write("-- dump rather than a redraw of the table above, because\n")
        f.write("-- the client honours the alpha channel whatever blend\n")
        f.write("-- mode a texture is given. Empty unless the build ran\n")
        f.write("-- with --original, and Config.lua hides the in-game\n")
        f.write("-- \"Original\" background when it is.\n")
        if orig and orig["entries"]:
            f.write(
                f"-- {len(orig['entries'])} textures across "
                f"{len(orig['covered'])} zones\n"
            )
            f.write("HFWMF_FDID_MAP_ORIGINAL = {\n")
            _write_entries(f, orig["entries"])
            f.write("}\n")
        else:
            f.write("HFWMF_FDID_MAP_ORIGINAL = {}\n")

        f.write(
            "\n-- Higher-resolution World and Continent maps: art layer sized "
            "for the\n"
            "-- minimap's own source density, capped (see "
            "hfwm/gamedata/db2.py's\n"
            "-- _hires_geometry and HIRES_CONTINENT_MAPS), instead of "
            "Blizzard's fixed\n"
            "-- layer. Keyed by UiMapID, not FileDataID -- these draw a bigger "
            "grid than\n"
            "-- the client's own art layer describes, so Renderer.lua uses this "
            "geometry\n"
            "-- and path prefix directly instead of C_Map.GetMapArtLayers / "
            "GetMapArtLayerTextures.\n"
        )
        if native_main["entries"]:
            f.write(
                f"-- {len(native_main['entries'])} zones, "
                f"{sum(g['cols'] * g['rows'] for g in native_main['entries'].values())} "
                "textures\n"
            )
        _write_native_zones(f, "HFWMF_NATIVE_ZONES", native_main["entries"])

        f.write(
            "\n-- Same, for the raw --original dump. Empty unless that "
            "dump exists.\n"
        )
        if native_orig and native_orig["entries"]:
            _write_native_zones(
                f, "HFWMF_NATIVE_ZONES_ORIGINAL", native_orig["entries"],
            )
        else:
            f.write("HFWMF_NATIVE_ZONES_ORIGINAL = {}\n")

    extra = ""
    if orig and orig["entries"]:
        extra = (f", plus {len(orig['entries'])} raw textures across "
                 f"{len(orig['covered'])} zones")
    print(
        f"  Generated FDIDMap.lua: {len(main['entries'])} textures, "
        f"{len(main['covered'])} zones{extra}.",
        flush=True,
    )
    if native_main["entries"]:
        native_tiles = sum(
            g["cols"] * g["rows"] for g in native_main["entries"].values()
        )
        native_extra = ""
        if native_orig and native_orig["entries"]:
            orig_tiles = sum(
                g["cols"] * g["rows"] for g in native_orig["entries"].values()
            )
            native_extra = (
                f", plus {orig_tiles} raw textures across "
                f"{len(native_orig['covered'])} zones"
            )
        print(
            f"  Native-resolution zones: {native_tiles} textures across "
            f"{len(native_main['covered'])} zones{native_extra}.",
            flush=True,
        )

