"""CLI and orchestrator for ``generateHFWM.py`` (Forever build).

Four phases:

  1. Zone database  — build-pinned DB2 exports + WDT MAID chunks
  2. Tile download  — every unique minimap tile FDID, cached on disk
  3. Zone processing — stitch, crop, fit the art layer, encode BLP2
     3b. the same again with every art pass off, into ``Original/``
  4. FDIDMap.lua    — FileDataID -> bundled texture path

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
"""

from __future__ import annotations

import argparse
import os
import sys
import time
from collections import Counter
from concurrent.futures import ProcessPoolExecutor, ThreadPoolExecutor, as_completed
from multiprocessing import cpu_count
from pathlib import Path
from urllib.error import HTTPError, URLError

from .constants import (
    BASE_ART_TILE_CACHE,
    GAME_BUILD,
    GAME_PRODUCT,
    MAID_FIELD_MAPTEXTURE,
    MAID_FIELD_MINIMAP,
    MINIMAP_TILE_CACHE,
    ORIGINAL_SUBDIR,
    WORLDMAP_DIR,
)
from .db2 import fetch_zone_db
from .effects import ART_PASSES, banner_lines, resolve, stamp
from .fdid_map import generate_fdid_map
from .fmt import format_size, format_time
from .http import download_casc_cached
from .zone import process_zone_job


# ---------------------------------------------------------------------------
# Phase 2: minimap tile downloader
# ---------------------------------------------------------------------------

def download_tiles(
    all_fdids: set[int],
    cache_dir: Path = MINIMAP_TILE_CACHE,
    label: str = "minimap",
    max_workers: int = 8,
) -> dict[int, Path]:
    """Download BLP tiles by FDID from wago.tools, with local caching.

    Used for both the minimap terrain tiles and — when the base-art pass
    is on — Blizzard's own art-layer tiles; the endpoint is the same and
    keyed by FDID either way, so only *cache_dir* and the wording differ.
    """
    cache_dir.mkdir(parents=True, exist_ok=True)

    cached: dict[int, Path] = {}
    to_download: list[int] = []
    for fdid in sorted(all_fdids):
        p = cache_dir / f"{fdid}.blp"
        if p.exists() and p.stat().st_size > 0:
            cached[fdid] = p
        else:
            to_download.append(fdid)

    if not to_download:
        print(f"  All {len(cached)} {label} tiles already cached.", flush=True)
        return cached

    print(f"  {len(cached)} cached, {len(to_download)} to download ...",
          flush=True)

    done = 0
    failed: list[int] = []
    t0 = time.time()

    def _dl(fdid: int) -> tuple[int, Path | None]:
        try:
            return fdid, download_casc_cached(fdid, cache_dir)
        except Exception:
            return fdid, None

    with ThreadPoolExecutor(max_workers=max_workers) as pool:
        futures = {pool.submit(_dl, f): f for f in to_download}
        for fut in as_completed(futures):
            fdid, path = fut.result()
            if path:
                cached[fdid] = path
            else:
                failed.append(fdid)
            done += 1
            if done % 100 == 0 or done == len(to_download):
                elapsed = time.time() - t0
                rate = done / elapsed if elapsed > 0 else 0
                eta = (len(to_download) - done) / rate if rate > 0 else 0
                print(
                    f"\r    [{done}/{len(to_download)}] "
                    f"{len(failed)} failed  ETA: {format_time(eta)}   ",
                    end="", flush=True,
                )

    print(flush=True)
    if failed:
        print(f"  Warning: {len(failed)} {label} tiles failed to download "
              f"(e.g. {failed[:5]}).", flush=True)
    return cached


def _tile_size_histogram(
    tile_cache: dict[int, Path],
    limit: int = 400,
) -> None:
    """Log a size histogram of the downloaded tiles.

    Cheap sanity check: this build should be overwhelmingly 512px.  A
    large 256px population is fine (they get upscaled) but worth seeing;
    anything else suggests the CASC endpoint served a different product.
    """
    from PIL import Image

    counts: Counter[str] = Counter()
    for path in list(tile_cache.values())[:limit]:
        try:
            with Image.open(path) as img:
                counts[f"{img.size[0]}x{img.size[1]}"] += 1
        except Exception:
            counts["unreadable"] += 1
    sample = sum(counts.values())
    if sample:
        summary = ", ".join(
            f"{k}: {v}" for k, v in counts.most_common(6)
        )
        print(f"  Tile sizes (sample of {sample}): {summary}", flush=True)


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------

def _add_art_pass_args(parser: argparse.ArgumentParser) -> None:
    """Generate the flags for every pass in :data:`ART_PASSES`.

    Nothing here knows what any individual pass does — add one to the
    registry and its flags, help text, defaults and validation appear
    without touching this file.  ``default=None`` on the toggles is what
    lets :func:`effects.resolve` tell "explicitly asked for" apart from
    "left at its default", which is how supersede conflicts get caught.
    """
    group = parser.add_argument_group(
        "art passes",
        "Transforms applied to the stitched art. Each is independently "
        "toggleable; --no-art-passes turns the lot off for a raw stitch.",
    )
    group.add_argument(
        "--list-art-passes",
        action="store_true",
        help="Describe every available art pass and exit",
    )
    group.add_argument(
        "--no-art-passes",
        action="store_true",
        help="Disable every art pass — the raw stitch, gaps left black",
    )
    for p in ART_PASSES:
        state = "on" if p.default else "off"
        # BooleanOptionalAction derives the --no-<name> form itself.
        group.add_argument(
            f"--{p.name}",
            dest=p.dest,
            default=None,
            action=argparse.BooleanOptionalAction,
            help=f"{p.summary} (default: {state})",
        )
        for opt in p.options:
            group.add_argument(
                f"--{p.name}-{opt.name}",
                dest=f"{p.dest}_{opt.dest}",
                metavar=opt.metavar,
                default=opt.default,
                help=f"[--{p.name}] {opt.help} (default: {opt.default})",
            )

    # Back-compat: --no-ocean-fill predates the registry and is what the
    # first ocean commit shipped.  Kept working, hidden from --help so the
    # generated --no-ocean is the one that gets discovered.
    group.add_argument(
        "--no-ocean-fill",
        dest="no_ocean_fill",
        action="store_true",
        help=argparse.SUPPRESS,
    )


def _print_art_passes() -> None:
    """Long-form ``--list-art-passes`` output."""
    print("Art passes:\n")
    for p in ART_PASSES:
        print(f"  --{p.name}" + (" " * max(1, 22 - len(p.name)))
              + f"default: {'on' if p.default else 'off'}")
        print(f"      {p.summary}")
        for note in p.notes:
            print(f"      {note}")
        for opt in p.options:
            print(f"      --{p.name}-{opt.name} {opt.metavar}  "
                  f"(default: {opt.default})")
        if p.supersedes:
            print("      supersedes: "
                  + ", ".join(f"--{s}" for s in p.supersedes))
        print()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Generate high-fidelity world map textures for World of "
            f"Warcraft Forever ({GAME_PRODUCT} {GAME_BUILD}) by stitching "
            "the game's own minimap terrain tiles. Outputs uncompressed "
            "BGRA BLP2 tiles plus FDIDMap.lua."
        ),
    )
    parser.add_argument(
        "output_dir",
        nargs="?",
        default=str(WORLDMAP_DIR),
        help=f"Output directory for generated tiles (default: {WORLDMAP_DIR})",
    )
    parser.add_argument(
        "--zones",
        default=None,
        help="Comma-separated zone folder names to include (default: all)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report the plan without downloading tiles or writing files",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Force re-download of the DB2 exports and zone DB",
    )
    parser.add_argument(
        "--skip-fdid-map",
        action="store_true",
        help="Skip FDIDMap.lua generation",
    )
    parser.add_argument(
        "--original",
        default=True,
        action=argparse.BooleanOptionalAction,
        help=(
            f"Also write a raw, art-pass-free dump to {ORIGINAL_SUBDIR}/, "
            "which backs the in-game Original background. Roughly doubles "
            "the output size and the processing time (default: on)"
        ),
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=max(2, cpu_count() - 1),
        help=f"Zone processing workers (default: {max(2, cpu_count() - 1)})",
    )
    parser.add_argument(
        "--dl-threads",
        type=int,
        default=8,
        help="Parallel download threads (default: 8)",
    )
    _add_art_pass_args(parser)
    parser.add_argument(
        "--maid-field",
        type=int,
        default=MAID_FIELD_MINIMAP,
        choices=[MAID_FIELD_MAPTEXTURE, MAID_FIELD_MINIMAP],
        help=(
            f"MAID field for tile FDIDs. {MAID_FIELD_MINIMAP} = "
            f"minimapTexture (default). {MAID_FIELD_MAPTEXTURE} = "
            "mapTexture, the terrain LOD diffuse."
        ),
    )
    return parser


# ---------------------------------------------------------------------------
# Phase 3b: the raw second dump
# ---------------------------------------------------------------------------

def run_original_pass(
    zone_db: dict[str, dict],
    tile_cache_str: dict[str, str],
    output_dir: str,
    threads: int,
) -> dict:
    """Write the raw, art-pass-free dump under ``<output_dir>/Original/``.

    Phase 3 again with ``passes={}``: the same stitch, crop and geometry
    with none of the transforms, so the FDIDs line up tile for tile with
    the main table and the addon can swap between the two without
    re-laying anything out.

    Reported as a single progress counter rather than a line per zone —
    phase 3 has already printed one of those for each, and the geometry it
    would report is by construction identical.
    """
    dst = os.path.join(output_dir, ORIGINAL_SUBDIR)
    os.makedirs(dst, exist_ok=True)
    jobs = [
        (zone_db[folder], tile_cache_str, dst, {}, {})
        for folder in sorted(zone_db)
    ]

    ok = 0
    done = 0
    tiles = 0
    total_bytes = 0
    failed: list[str] = []
    t0 = time.time()

    def _handle(folder: str, res: dict) -> None:
        nonlocal ok, done, tiles, total_bytes
        done += 1
        if res["status"] == "ok":
            ok += 1
            tiles += res["tiles"]
            total_bytes += res["bytes"]
        elif res["status"] == "error":
            failed.append(f"{folder}: {res.get('reason', '?')}")
        elapsed = time.time() - t0
        eta = (len(jobs) - done) * elapsed / done if done else 0
        print(f"\r    [{done}/{len(jobs)}] {tiles} BLP  "
              f"{format_size(total_bytes)}  ETA: {format_time(eta)}   ",
              end="", flush=True)

    if threads <= 1 or len(jobs) <= 2:
        for job in jobs:
            folder, res = process_zone_job(job)
            _handle(folder, res)
    else:
        with ProcessPoolExecutor(max_workers=threads) as pool:
            futures = {
                pool.submit(process_zone_job, job): job[0]["folder"]
                for job in jobs
            }
            for fut in as_completed(futures):
                folder, res = fut.result()
                _handle(folder, res)

    print(flush=True)
    print(f"  {ok}/{len(jobs)} zones, {tiles} BLPs, "
          f"{format_size(total_bytes)} in {format_time(time.time() - t0)}",
          flush=True)
    if failed:
        print(f"  {len(failed)} zone(s) FAILED:", flush=True)
        for line in failed[:10]:
            print(f"    {line}", flush=True)

    return {"zones": ok, "tiles": tiles, "bytes": total_bytes,
            "failed": len(failed)}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    args = build_parser().parse_args()

    if args.list_art_passes:
        _print_art_passes()
        return

    output_dir = os.path.abspath(args.output_dir)

    requested = {p.name: getattr(args, p.dest) for p in ART_PASSES}
    if args.no_ocean_fill:            # deprecated alias for --no-ocean
        requested["ocean"] = False
    try:
        passes, pass_notes = resolve(
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

    ocean_opts = passes.get("ocean")
    ocean_rgb = ocean_opts["color"] if ocean_opts else None
    want_base_art = "base-art" in passes
    want_alpha_sea = "alpha-sea" in passes

    print("=" * 66, flush=True)
    print("  High Fidelity World Map Forever — texture generator", flush=True)
    print("=" * 66, flush=True)
    print(f"Product:   {GAME_PRODUCT}", flush=True)
    print(f"Build:     {GAME_BUILD}", flush=True)
    print(f"Output:    {output_dir}", flush=True)
    print(f"Threads:   {args.threads} processing, {args.dl_threads} download",
          flush=True)
    print(f"Encoding:  uncompressed BGRA BLP2", flush=True)
    print(f"MAID field:{args.maid_field}", flush=True)
    for i, line in enumerate(banner_lines(passes)):
        print(f"{'Art pass:' if i == 0 else '':<11}{line}", flush=True)
    for note in pass_notes:
        print(f"{'':<11}note: {note}", flush=True)
    print(flush=True)

    # --- Phase 1: zone database ---------------------------------------
    print("--- Phase 1: Zone database ---", flush=True)
    try:
        zone_db = fetch_zone_db(
            force_refresh=args.refresh,
            maid_field=args.maid_field,
        )
    except (URLError, HTTPError, OSError) as exc:
        print(f"  ERROR: could not build the zone DB: {exc}", file=sys.stderr)
        sys.exit(1)

    if not zone_db:
        print("  ERROR: zone DB is empty — nothing to do.", file=sys.stderr)
        sys.exit(1)

    if args.zones:
        wanted = {z.strip().lower() for z in args.zones.split(",")}
        zone_db = {
            k: v for k, v in zone_db.items()
            if k.lower() in wanted or v["area_name"].lower() in wanted
        }
        if not zone_db:
            print("  ERROR: no zones matched --zones.", file=sys.stderr)
            sys.exit(1)

    grids = Counter(f"{z['cols']}x{z['rows']}" for z in zone_db.values())
    needed_fdids = {
        fdid
        for z in zone_db.values()
        for reg in z["regions"]
        for fdid in reg["tiles"].values()
    }
    out_tiles = sum(z["cols"] * z["rows"] for z in zone_db.values())

    print(f"\nZones:     {len(zone_db)}", flush=True)
    print(f"Grids:     "
          + ", ".join(f"{k} x{v}" for k, v in grids.most_common()),
          flush=True)
    print(f"Src tiles: {len(needed_fdids)} unique minimap textures",
          flush=True)
    print(f"Out tiles: {out_tiles} BLPs", flush=True)

    if args.dry_run:
        print(flush=True)
        for folder in sorted(zone_db):
            z = zone_db[folder]
            src = sum(len(r["tiles"]) for r in z["regions"])
            print(
                f"  {folder:34s} {z['cols']}x{z['rows']} "
                f"{z['layer_w']}x{z['layer_h']:<5} "
                f"{len(z['regions'])} region(s)  {src:4d} src tiles  "
                f"[{z['area_name']}]",
            )
        print("\n(dry run — nothing downloaded or written)")
        return

    # --- Phase 2: download tiles --------------------------------------
    print("\n--- Phase 2: Downloading minimap tiles ---", flush=True)
    tile_cache = download_tiles(
        needed_fdids, MINIMAP_TILE_CACHE, "minimap", args.dl_threads,
    )
    _tile_size_histogram(tile_cache)

    base_art_cache: dict[int, Path] = {}
    if want_base_art:
        # The base-art backdrop is built from the very FDIDs the addon
        # remaps — the client's own art-layer tiles for each zone.
        art_fdids = {
            fdid for z in zone_db.values() for fdid in z["tile_fdids"]
        }
        print(f"\n--- Phase 2b: Downloading base art ({len(art_fdids)} "
              f"tiles) ---", flush=True)
        base_art_cache = download_tiles(
            art_fdids, BASE_ART_TILE_CACHE, "base art", args.dl_threads,
        )
        if not base_art_cache:
            print("  ERROR: --base-art is on but no original art tiles "
                  "could be downloaded.", file=sys.stderr)
            sys.exit(1)

    # --- Phase 3: process zones ---------------------------------------
    print(f"\n--- Phase 3: Processing zones ({args.threads} workers) ---",
          flush=True)
    os.makedirs(output_dir, exist_ok=True)
    tile_cache_str = {str(k): str(v) for k, v in tile_cache.items()}
    base_art_str = {str(k): str(v) for k, v in base_art_cache.items()}
    jobs = [
        (zone_db[folder], tile_cache_str, output_dir, passes, base_art_str)
        for folder in sorted(zone_db)
    ]

    ok = 0
    skipped: list[str] = []
    failed: list[str] = []
    total_bytes = 0
    total_out_tiles = 0
    upscaled = 0
    dropped = 0
    holes = 0
    sea_cells = 0
    sea_zones = 0
    base_art_zones = 0
    t0 = time.time()

    def _handle(folder: str, res: dict) -> None:
        nonlocal ok, total_bytes, total_out_tiles, upscaled, dropped, holes
        nonlocal sea_cells, sea_zones, base_art_zones
        status = res["status"]
        if status == "ok":
            ok += 1
            total_bytes += res["bytes"]
            total_out_tiles += res["tiles"]
            mm = res["minimap"]
            upscaled += mm["upscaled"]
            dropped += mm["too_small"] + mm["unreadable"] + mm["missing"]
            hole = mm["cells"] - mm["loaded"]
            holes += max(0, hole)
            filled = mm.get("ocean_cells", 0)
            sea_cells += filled
            sea_zones += 1 if res.get("has_ocean") else 0
            base_art_zones += 1 if res.get("base_art") else 0
            if hole > 0:
                extra = f"  {hole} empty cells"
                if filled:
                    if res.get("base_art"):
                        extra += " (base art)"
                    elif res.get("alpha_sea"):
                        extra += " (transparent)"
                    else:
                        extra += f" ({filled} sea)"
            else:
                extra = ""
            sp = "/".join(str(p) for p in res.get("stitch_px", [])) or "-"
            print(
                f"  {folder:34s} {res['grid']:>5}  {res['tiles']:3d} BLP  "
                f"{res['layer']:>9} -> {res['output']:>9}"
                f"  {mm['loaded']:4d} src @{sp}px{extra}",
                flush=True,
            )
            for note in res.get("notes", []):
                print(f"      note: {note}", flush=True)
        elif status == "skip":
            skipped.append(f"{folder}: {res.get('reason', '?')}")
        else:
            failed.append(f"{folder}: {res.get('reason', '?')}")
            print(f"  {folder:34s} FAILED", flush=True)

    if args.threads <= 1 or len(jobs) <= 2:
        for job in jobs:
            folder, res = process_zone_job(job)
            _handle(folder, res)
    else:
        with ProcessPoolExecutor(max_workers=args.threads) as pool:
            futures = {
                pool.submit(process_zone_job, job): job[0]["folder"]
                for job in jobs
            }
            for fut in as_completed(futures):
                folder, res = fut.result()
                _handle(folder, res)

    print(
        f"\nProcessed {ok}/{len(jobs)} zones in "
        f"{format_time(time.time() - t0)} — "
        f"{total_out_tiles} BLPs, {format_size(total_bytes)}",
        flush=True,
    )
    if upscaled:
        print(f"  {upscaled} source tiles upscaled from sub-512px",
              flush=True)
    if dropped:
        print(f"  {dropped} source tiles unusable (too small / "
              f"unreadable / not downloaded)", flush=True)
    if holes:
        if want_base_art:
            print(
                f"  {holes} stitch cells had no minimap coverage — "
                f"showing Blizzard's own art through",
                flush=True,
            )
        elif want_alpha_sea:
            print(
                f"  {holes} stitch cells had no minimap coverage — left "
                f"transparent for the in-game background to fill",
                flush=True,
            )
        elif ocean_rgb is None:
            print(f"  {holes} stitch cells left black (no minimap coverage)",
                  flush=True)
        else:
            print(
                f"  {holes} stitch cells had no minimap coverage — "
                f"{sea_cells} filled with sea, {holes - sea_cells} left "
                f"black (no open water alongside)",
                flush=True,
            )
    if want_base_art:
        print(
            f"  {base_art_zones}/{ok} zones composited over their original "
            f"hand-painted art; the sea and every gap come from it",
            flush=True,
        )
    elif want_alpha_sea:
        print(
            f"  {sea_zones}/{ok} zones have sea, shipped transparent — pick "
            f"the backdrop in game with /hfwm bg or the options panel",
            flush=True,
        )
    elif ocean_rgb is not None:
        ocean_hex = "#%02X%02X%02X" % ocean_rgb
        print(
            f"  {sea_zones}/{ok} zones have sea, unified to {ocean_hex} "
            f"along with their uncovered art-layer background",
            flush=True,
        )
    if skipped:
        print(f"\n  {len(skipped)} zone(s) skipped:", flush=True)
        for line in skipped[:20]:
            print(f"    {line}", flush=True)
    if failed:
        print(f"\n  {len(failed)} zone(s) FAILED:", flush=True)
        for line in failed[:10]:
            print(f"    {line}", flush=True)

    # --- Phase 3b: the raw second dump --------------------------------
    original_dir = os.path.join(output_dir, ORIGINAL_SUBDIR)
    # With no art passes enabled the primary output already *is* the raw
    # stitch, so a byte-identical second copy would only cost disk.  The
    # Original table is then left empty, which is exactly how the addon
    # knows to drop the entry from its dropdown — there is nothing to pick
    # between.
    want_original = bool(args.original and passes)

    if want_original:
        print(f"\n--- Phase 3b: Raw dump into {ORIGINAL_SUBDIR}/ "
              f"({args.threads} workers) ---", flush=True)
        run_original_pass(zone_db, tile_cache_str, output_dir, args.threads)
    elif args.original:
        print(f"\n  Skipping the {ORIGINAL_SUBDIR}/ dump: no art passes are "
              f"enabled, so the main output is already the raw stitch.",
              flush=True)
    elif os.path.isdir(original_dir):
        print(f"\n  WARNING: --no-original was given but {ORIGINAL_SUBDIR}/ "
              f"still exists from an earlier build. It is left alone and "
              f"will be picked up by phase 4; delete it to drop the "
              f"in-game Original background.", flush=True)

    # --- Phase 4: FDIDMap.lua -----------------------------------------
    if args.skip_fdid_map:
        return
    print("\n--- Phase 4: Generating FDIDMap.lua ---", flush=True)
    try:
        # Scan the raw tree whenever one is on disk, not only when this run
        # wrote it: a rebuild with --no-original should not silently strip a
        # background whose art is still installed.
        summary = generate_fdid_map(
            output_dir, zone_db, stamp(passes),
            original=want_original or os.path.isdir(original_dir),
        )
    except OSError as exc:
        print(f"  Warning: FDIDMap.lua generation failed: {exc}", flush=True)
        return

    if summary["entries"] != total_out_tiles:
        print(
            f"  NOTE: {summary['entries']} map entries vs "
            f"{total_out_tiles} BLPs written — "
            f"{summary['missing']} expected files were absent.",
            flush=True,
        )
    if summary["original_entries"]:
        print(
            f"  In-game Original background available: "
            f"{summary['original_entries']} raw textures across "
            f"{summary['original_zones']} zones.",
            flush=True,
        )
