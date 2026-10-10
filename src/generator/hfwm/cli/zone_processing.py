"""Phase 3 and 3b: running the zone jobs and reporting what they did."""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field

from ..config.paths import ORIGINAL_SUBDIR
from ..infra.fmt import format_size, format_time
from ..pipeline.runner import run_zone_jobs


@dataclass
class ZoneRunStats:
    """Running totals for phase 3, filled in as each zone finishes."""

    ok: int = 0
    skipped: list[str] = field(default_factory=list)
    failed: list[str] = field(default_factory=list)
    total_bytes: int = 0
    total_out_tiles: int = 0
    upscaled: int = 0
    dropped: int = 0
    holes: int = 0
    sea_cells: int = 0
    sea_zones: int = 0
    base_art_zones: int = 0

    def record(self, folder: str, res: dict) -> None:
        """Fold one zone's result in, printing its line."""
        status = res["status"]
        if status == "ok":
            self.ok += 1
            self.total_bytes += res["bytes"]
            self.total_out_tiles += res["tiles"]
            mm = res["minimap"]
            self.upscaled += mm["upscaled"]
            self.dropped += mm["too_small"] + mm["unreadable"] + mm["missing"]
            hole = mm["cells"] - mm["loaded"]
            self.holes += max(0, hole)
            filled = mm.get("ocean_cells", 0)
            self.sea_cells += filled
            self.sea_zones += 1 if res.get("has_ocean") else 0
            self.base_art_zones += 1 if res.get("base_art") else 0
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
            self.skipped.append(f"{folder}: {res.get('reason', '?')}")
        else:
            self.failed.append(f"{folder}: {res.get('reason', '?')}")
            print(f"  {folder:34s} FAILED", flush=True)

    def report(
        self,
        job_count: int,
        elapsed: float,
        *,
        want_base_art: bool,
        want_alpha_sea: bool,
        ocean_rgb: tuple[int, int, int] | None,
    ) -> None:
        """Print the end-of-phase summary."""
        ok = self.ok
        print(
            f"\nProcessed {ok}/{job_count} zones in "
            f"{format_time(elapsed)} — "
            f"{self.total_out_tiles} BLPs, {format_size(self.total_bytes)}",
            flush=True,
        )
        if self.upscaled:
            print(f"  {self.upscaled} source tiles upscaled from sub-512px",
                  flush=True)
        if self.dropped:
            print(f"  {self.dropped} source tiles unusable (too small / "
                  f"unreadable / not downloaded)", flush=True)
        if self.holes:
            self._report_holes(want_base_art, want_alpha_sea, ocean_rgb)
        if want_base_art:
            print(
                f"  {self.base_art_zones}/{ok} zones composited over their "
                f"original hand-painted art; the sea and every gap come "
                f"from it",
                flush=True,
            )
        elif want_alpha_sea:
            print(
                f"  {self.sea_zones}/{ok} zones have sea, shipped "
                f"transparent — pick the backdrop in game with /hfwm bg or "
                f"the options panel",
                flush=True,
            )
        elif ocean_rgb is not None:
            ocean_hex = "#%02X%02X%02X" % ocean_rgb
            print(
                f"  {self.sea_zones}/{ok} zones have sea, unified to "
                f"{ocean_hex} along with their uncovered art-layer "
                f"background",
                flush=True,
            )
        if self.skipped:
            print(f"\n  {len(self.skipped)} zone(s) skipped:", flush=True)
            for line in self.skipped[:20]:
                print(f"    {line}", flush=True)
        if self.failed:
            print(f"\n  {len(self.failed)} zone(s) FAILED:", flush=True)
            for line in self.failed[:10]:
                print(f"    {line}", flush=True)

    def _report_holes(
        self,
        want_base_art: bool,
        want_alpha_sea: bool,
        ocean_rgb: tuple[int, int, int] | None,
    ) -> None:
        holes = self.holes
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
                f"{self.sea_cells} filled with sea, "
                f"{holes - self.sea_cells} left black (no open water "
                f"alongside)",
                flush=True,
            )


def _stringify(cache: dict) -> dict[str, str]:
    """Job payloads cross a process boundary, so paths travel as strings."""
    return {str(k): str(v) for k, v in cache.items()}


def zone_output_dir(zone: dict, output_dir: str, lowres_dir: str) -> str:
    """Where *zone*'s tiles go: HD maps to the Art addon, the rest to the client."""
    return output_dir if zone.get("native") else lowres_dir


def process_zones(
    zone_db: dict[str, dict],
    tile_cache: dict[int, object],
    base_art_cache: dict[int, object],
    output_dir: str,
    lowres_dir: str,
    passes: dict,
    threads: int,
    *,
    ocean_rgb: tuple[int, int, int] | None,
) -> ZoneRunStats:
    """Phase 3: stitch, crop, fit and encode every zone."""
    tile_cache_str = _stringify(tile_cache)
    base_art_str = _stringify(base_art_cache)
    jobs = [
        (zone_db[folder], tile_cache_str,
         zone_output_dir(zone_db[folder], output_dir, lowres_dir),
         passes, base_art_str)
        for folder in sorted(zone_db)
    ]

    stats = ZoneRunStats()
    t0 = time.time()
    run_zone_jobs(jobs, threads, stats.record)
    stats.report(
        len(jobs),
        time.time() - t0,
        want_base_art="base-art" in passes,
        want_alpha_sea="alpha-sea" in passes,
        ocean_rgb=ocean_rgb,
    )
    return stats


def run_original_pass(
    zone_db: dict[str, dict],
    tile_cache: dict[int, object],
    output_dir: str,
    lowres_dir: str,
    threads: int,
) -> dict:
    """Write the raw, art-pass-free dump under ``<dir>/Original/``.

    ``<dir>`` is ``output_dir`` for the HD maps and ``lowres_dir`` for the rest.

    Phase 3 again with ``passes={}``: the same stitch, crop and geometry
    with none of the transforms, so the FDIDs line up tile for tile with
    the main table and the addon can swap between the two without
    re-laying anything out.

    Reported as a single progress counter rather than a line per zone —
    phase 3 has already printed one of those for each, and the geometry it
    would report is by construction identical.
    """
    tile_cache_str = _stringify(tile_cache)
    jobs = [
        (zone_db[folder], tile_cache_str,
         os.path.join(zone_output_dir(zone_db[folder], output_dir, lowres_dir),
                      ORIGINAL_SUBDIR),
         {}, {})
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

    run_zone_jobs(jobs, threads, _handle)

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
