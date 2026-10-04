"""Running zone jobs, in-process or across a worker pool."""

from __future__ import annotations

from concurrent.futures import ProcessPoolExecutor, as_completed
from typing import Callable

from .zone import process_zone_job

# Below this many jobs a pool's startup costs more than it saves.
_MIN_JOBS_FOR_POOL = 3


def run_zone_jobs(
    jobs: list[tuple],
    threads: int,
    on_result: Callable[[str, dict], None],
) -> None:
    """Run every job through :func:`process_zone_job`.

    *on_result* is called as ``on_result(folder, result)`` in the parent
    process as each job finishes — in submission order when run in-process,
    in completion order from a pool.
    """
    if threads <= 1 or len(jobs) < _MIN_JOBS_FOR_POOL:
        for job in jobs:
            folder, res = process_zone_job(job)
            on_result(folder, res)
        return

    with ProcessPoolExecutor(max_workers=threads) as pool:
        futures = {
            pool.submit(process_zone_job, job): job[0]["folder"]
            for job in jobs
        }
        for fut in as_completed(futures):
            folder, res = fut.result()
            on_result(folder, res)
