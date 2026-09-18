"""CLI and orchestrator for ``generateHFWM.py`` (Forever build).

Four phases:

  1. Zone database  — build-pinned DB2 exports + WDT MAID chunks
  2. Tile download  — every unique minimap tile FDID, cached on disk
  3. Zone processing — stitch, crop, fit the art layer, encode BLP2
  4. FDIDMap.lua    — FileDataID -> bundled texture path

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
    GAME_BUILD,
    GAME_PRODUCT,
    MAID_FIELD_MAPTEXTURE,
    MAID_FIELD_MINIMAP,
    MINIMAP_TILE_CACHE,
    WORLDMAP_DIR,
)
from .db2 import fetch_zone_db
from .fdid_map import generate_fdid_map
from .fmt import format_size, format_time
from .http import download_casc_cached
from .zone import process_zone_job


# ---------------------------------------------------------------------------
# Phase 2: minimap tile downloader
# ---------------------------------------------------------------------------

def download_minimap_tiles(
    all_fdids: set[int],
    max_workers: int = 8,
) -> dict[int, Path]:
    """Download minimap BLP tiles from wago.tools with local caching."""
    MINIMAP_TILE_CACHE.mkdir(parents=True, exist_ok=True)

    cached: dict[int, Path] = {}
    to_download: list[int] = []
    for fdid in sorted(all_fdids):
        p = MINIMAP_TILE_CACHE / f"{fdid}.blp"
        if p.exists() and p.stat().st_size > 0:
            cached[fdid] = p
        else:
            to_download.append(fdid)

    if not to_download:
        print(f"  All {len(cached)} minimap tiles already cached.", flush=True)
        return cached

    print(f"  {len(cached)} cached, {len(to_download)} to download ...",
          flush=True)

    done = 0
    failed: list[int] = []
    t0 = time.time()

    def _dl(fdid: int) -> tuple[int, Path | None]:
        try:
            return fdid, download_casc_cached(fdid, MINIMAP_TILE_CACHE)
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
        print(f"  Warning: {len(failed)} tiles failed to download "
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
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    args = build_parser().parse_args()
    output_dir = os.path.abspath(args.output_dir)

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
    tile_cache = download_minimap_tiles(needed_fdids, args.dl_threads)
    _tile_size_histogram(tile_cache)

    # --- Phase 3: process zones ---------------------------------------
    print(f"\n--- Phase 3: Processing zones ({args.threads} workers) ---",
          flush=True)
    os.makedirs(output_dir, exist_ok=True)
    tile_cache_str = {str(k): str(v) for k, v in tile_cache.items()}
    jobs = [
        (zone_db[folder], tile_cache_str, output_dir)
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
    t0 = time.time()

    def _handle(folder: str, res: dict) -> None:
        nonlocal ok, total_bytes, total_out_tiles, upscaled, dropped, holes
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
            extra = f"  {hole} empty cells" if hole > 0 else ""
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
        print(f"  {holes} stitch cells left black (no minimap coverage)",
              flush=True)
    if skipped:
        print(f"\n  {len(skipped)} zone(s) skipped:", flush=True)
        for line in skipped[:20]:
            print(f"    {line}", flush=True)
    if failed:
        print(f"\n  {len(failed)} zone(s) FAILED:", flush=True)
        for line in failed[:10]:
            print(f"    {line}", flush=True)

    # --- Phase 4: FDIDMap.lua -----------------------------------------
    if args.skip_fdid_map:
        return
    print("\n--- Phase 4: Generating FDIDMap.lua ---", flush=True)
    try:
        summary = generate_fdid_map(output_dir, zone_db)
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
