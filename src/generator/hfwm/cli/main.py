"""Orchestrator for ``generateHFWM.py`` (Forever build).

Five phases:

  1. Zone database  — build-pinned DB2 exports + WDT MAID chunks
  2. Tile download  — every unique minimap tile FDID, cached on disk
  3. Zone processing — stitch, crop, fit the art layer, encode BLP2, for the
     World and Continent maps only (:func:`hfwm.cli.phases.art_zones`)
     3b. the same again with every art pass off, into ``Original/``
  4. FDIDMap.lua    — FileDataID -> bundled texture path
  5. CaveData.lua   — the interior map table this build's UiMap lacks

Phase 5 is the odd one out: it ships no art of its own.  Blizzard's
interior tiles are already in the client, but this build's ``UiMap``
lists outdoor zones only, so nothing in Lua can reach them.  The pass
rebuilds the missing map rows offline — see
:mod:`hfwm.gamedata.microdungeon` for what is borrowed from retail and what
is validated against the pinned build — and bakes them into
``CaveData.lua``.  It touches the network independently of phases 1–3, so
``--caves-only`` runs it alone.

Phase 3b (``--original``, on by default) is what backs the in-game
"Original" background.  It has to be a real second dump: the art passes
change the pixels, and the raw stitch cannot be recovered from the
shipped art at draw time — an attempt to do that by drawing the
transparent tiles with ``SetBlendMode("DISABLE")`` failed, because this
client honours the alpha channel regardless of blend mode.  The cost is
another ~175 MB on disk and roughly double the phase-3 time, so
``--no-original`` is there for anyone who does not want the option.

There is no listfile phase, no AI/inpainting prompt, no zone presets and
no hybrid-submerge pass; those were retail-specific.

This module only sequences the phases.  Each lives in
:mod:`hfwm.cli.phases` or :mod:`hfwm.cli.zone_processing`.
"""

from __future__ import annotations

import argparse
import os
import sys

from ..config.build import GAME_BUILD, GAME_PRODUCT
from ..config.paths import CAVE_DATA_FILE, FDID_MAP_FILE, ORIGINAL_SUBDIR
from ..imaging.effects import ART_PASSES, banner_lines, resolve
from .parser import build_parser, print_art_passes
from .phases import (
    art_zones,
    download_source_tiles,
    load_zone_db,
    print_dry_run,
    print_plan,
    run_cave_pass,
    run_fdid_map_phase,
    source_fdids,
)
from .zone_processing import process_zones, run_original_pass


def _resolve_art_passes(args: argparse.Namespace) -> tuple[dict, list[str]]:
    """Turn the art-pass flags into the settings for each enabled pass.

    Exits with status 2 if the combination is contradictory.
    """
    requested = {p.name: getattr(args, p.dest) for p in ART_PASSES}
    if args.no_ocean_fill:            # deprecated alias for --no-ocean
        requested["ocean"] = False
    try:
        return resolve(
            requested,
            {
                f"{p.dest}_{o.dest}": getattr(args, f"{p.dest}_{o.dest}")
                for p in ART_PASSES for o in p.options
            },
            all_off=args.no_art_passes,
        )
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)


def _print_banner(
    args: argparse.Namespace,
    output_dir: str,
    lowres_dir: str,
    passes: dict,
    pass_notes: list[str],
) -> None:
    print("=" * 66, flush=True)
    print("  High Fidelity World Map — texture generator", flush=True)
    print("=" * 66, flush=True)
    print(f"Product:   {GAME_PRODUCT}", flush=True)
    print(f"Build:     {GAME_BUILD}", flush=True)
    print(f"Output:    {output_dir}  (HD)", flush=True)
    print(f"Low-res:   {lowres_dir}", flush=True)
    print(f"Threads:   {args.threads} processing, {args.dl_threads} download",
          flush=True)
    print("Encoding:  uncompressed BGRA BLP2", flush=True)
    print(f"MAID field:{args.maid_field}", flush=True)
    for i, line in enumerate(banner_lines(passes)):
        print(f"{'Art pass:' if i == 0 else '':<11}{line}", flush=True)
    for note in pass_notes:
        print(f"{'':<11}note: {note}", flush=True)
    print(flush=True)


def _has_original(*dirs: str) -> bool:
    """Is a raw ``Original/`` dump on disk under any of *dirs*?"""
    return any(os.path.isdir(os.path.join(d, ORIGINAL_SUBDIR)) for d in dirs)


def _run_original_phase(
    args: argparse.Namespace,
    zone_db: dict[str, dict],
    tile_cache: dict,
    output_dir: str,
    lowres_dir: str,
    passes: dict,
) -> bool:
    """Phase 3b.  Returns whether the raw dump was written this run."""
    # With no art passes enabled the primary output already *is* the raw
    # stitch, so a byte-identical second copy would only cost disk.  The
    # Original table is then left empty, which is exactly how the addon
    # knows to drop the entry from its dropdown — there is nothing to pick
    # between.
    want_original = bool(args.original and passes)

    if want_original:
        print(f"\n--- Phase 3b: Raw dump into {ORIGINAL_SUBDIR}/ "
              f"({args.threads} workers) ---", flush=True)
        run_original_pass(
            zone_db, tile_cache, output_dir, lowres_dir, args.threads,
        )
    elif args.original:
        print(f"\n  Skipping the {ORIGINAL_SUBDIR}/ dump: no art passes are "
              f"enabled, so the main output is already the raw stitch.",
              flush=True)
    elif _has_original(output_dir, lowres_dir):
        print(f"\n  WARNING: --no-original was given but {ORIGINAL_SUBDIR}/ "
              f"still exists from an earlier build. It is left alone and "
              f"will be picked up by phase 4; delete it to drop the "
              f"in-game Original background.", flush=True)
    return want_original


def main() -> None:
    args = build_parser().parse_args()

    if args.list_art_passes:
        print_art_passes()
        return

    if args.caves_only:
        print("--- Cave map table only ---", flush=True)
        print(f"Build:     {GAME_BUILD}", flush=True)
        print(f"Output:    {CAVE_DATA_FILE}", flush=True)
        print(flush=True)
        sys.exit(0 if run_cave_pass(args.refresh_caves) else 1)

    if args.tables_only:
        print("--- Lua tables only ---", flush=True)
        print(f"Build:     {GAME_BUILD}", flush=True)
        print(f"FDIDMap:   {FDID_MAP_FILE}", flush=True)
        print(f"CaveData:  {CAVE_DATA_FILE}", flush=True)
        print(flush=True)
        passes, _ = _resolve_art_passes(args)
        zone_db = art_zones(
            load_zone_db(args.refresh, args.maid_field, args.zones))
        if not args.skip_fdid_map:
            run_fdid_map_phase(
                os.path.abspath(args.output_dir),
                os.path.abspath(args.lowres_dir),
                zone_db,
                passes,
                # Same rule as phase 3b: no art passes means no raw dump.
                include_original=bool(args.original and passes),
                total_out_tiles=0,
                metadata_only=True,
            )
        if args.caves:
            run_cave_pass(args.refresh_caves)
        return

    output_dir = os.path.abspath(args.output_dir)
    lowres_dir = os.path.abspath(args.lowres_dir)
    passes, pass_notes = _resolve_art_passes(args)
    ocean_opts = passes.get("ocean")
    ocean_rgb = ocean_opts["color"] if ocean_opts else None

    _print_banner(args, output_dir, lowres_dir, passes, pass_notes)

    zone_db = load_zone_db(args.refresh, args.maid_field, args.zones)
    if args.lowres_only:
        # HD maps are the ones with native geometry (see zone_output_dir).
        zone_db = {k: v for k, v in zone_db.items() if not v.get("native")}
    # Every zone's source tiles are downloaded (the client-tile placement
    # scripts read them from the cache), but only the World and Continent
    # maps are stitched.
    needed_fdids = source_fdids(zone_db)
    art_db = art_zones(zone_db)
    print_plan(art_db, needed_fdids)

    if args.dry_run:
        print_dry_run(art_db, args.caves)
        return

    tile_cache, base_art_cache = download_source_tiles(
        zone_db, needed_fdids, args.dl_threads,
        want_base_art="base-art" in passes,
    )

    print(f"\n--- Phase 3: Processing zones ({args.threads} workers) ---",
          flush=True)
    stats = process_zones(
        art_db, tile_cache, base_art_cache, output_dir, lowres_dir, passes,
        args.threads, ocean_rgb=ocean_rgb,
    )

    wrote_original = _run_original_phase(
        args, art_db, tile_cache, output_dir, lowres_dir, passes,
    )

    if not args.skip_fdid_map:
        run_fdid_map_phase(
            output_dir, lowres_dir, art_db, passes,
            # Scan the raw tree whenever one is on disk, not only when this
            # run wrote it: a rebuild with --no-original should not silently
            # strip a background whose art is still installed.
            include_original=(
                wrote_original or _has_original(output_dir, lowres_dir)
            ),
            total_out_tiles=stats.total_out_tiles,
        )

    # Last, and deliberately after phase 4's early exits: it shares
    # nothing with the phases above — no zone DB, no tile cache, no art
    # passes — so a cave-table failure must not cost anyone the zone art
    # this run just spent its time producing.
    if args.caves:
        print("\n--- Phase 5: Generating CaveData.lua ---", flush=True)
        run_cave_pass(args.refresh_caves)
