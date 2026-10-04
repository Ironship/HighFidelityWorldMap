"""DB2 table downloads: one cached-CSV mechanism, two table families.

``wago.tools`` serves each DB2 as a CSV export.  The zone pipeline reads
the build-pinned exports; the interior pass additionally reads *donor*
exports from retail (see :mod:`hfwm.gamedata.microdungeon`).  Both go
through :func:`fetch_csv_cached`, and differ only in URL and cache
location, so a donor export can never be mistaken for a pinned one.
"""

from __future__ import annotations

from ..config.build import GAME_BUILD
from ..config.caching import DB2_CACHE_TTL_DAYS, DONOR_DB2_CACHE_TTL_DAYS
from ..config.endpoints import db2_url, donor_db2_url
from ..config.paths import DB2_CACHE_DIR, DONOR_DB2_CACHE_DIR
from ..infra.cache import CachedFile
from ..infra.http import fetch_csv

# Whole-table exports are large (UiMapArtTile is ~13 MB), so allow a slow link.
_CSV_TIMEOUT_SECONDS = 300


def fetch_csv_cached(
    url: str,
    cache: CachedFile,
    *,
    force_refresh: bool = False,
    empty_message: str | None = None,
) -> list[dict]:
    """Return the rows of the CSV at *url*, via *cache*.

    An empty export is an error rather than a result: it means the build
    or table is not on the server, and caching it would hide that.
    """
    if force_refresh:
        cache.discard()
    rows, _age = cache.load_or_none()
    if rows:
        return rows

    rows = fetch_csv(url, timeout=_CSV_TIMEOUT_SECONDS)
    if not rows:
        raise OSError(empty_message or f"{url} came back empty.")
    cache.save(rows)
    return rows


def fetch_pinned_table(table: str, force_refresh: bool = False) -> list[dict]:
    """Fetch one build-pinned DB2 export."""
    cache = CachedFile(DB2_CACHE_DIR / f"{table}.json", DB2_CACHE_TTL_DAYS)
    return fetch_csv_cached(
        db2_url(table),
        cache,
        force_refresh=force_refresh,
        empty_message=(
            f"{table}.db2 came back empty for build {GAME_BUILD}. "
            "The build may have been de-listed on wago.tools — check "
            "GAME_BUILD in hfwm/config/build.py."
        ),
    )


def fetch_donor_table(table: str, force_refresh: bool = False) -> list[dict]:
    """Fetch an *unpinned* (latest retail) DB2 export.

    Retail is the only place the interior rows exist.  Kept in its own
    cache directory so a retail FDID-keyed export can never be mistaken
    for one describing the pinned build.
    """
    cache = CachedFile(
        DONOR_DB2_CACHE_DIR / f"{table}.json", DONOR_DB2_CACHE_TTL_DAYS,
    )
    return fetch_csv_cached(
        donor_db2_url(table), cache, force_refresh=force_refresh,
    )
