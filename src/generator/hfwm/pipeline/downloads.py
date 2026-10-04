"""Phase 2: downloading source tiles from wago.tools."""

from __future__ import annotations

import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

from ..config.paths import MINIMAP_TILE_CACHE
from ..infra.fmt import format_time
from ..infra.http import download_casc_cached


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


def tile_size_histogram(
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
