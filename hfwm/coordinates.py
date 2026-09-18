"""World ↔ tile ↔ pixel coordinate math."""

from __future__ import annotations

import math

from .constants import MINIMAP_TILE_PX, TILE_WORLD_SIZE


def world_to_tile(coord: float) -> int:
    """Convert a world coordinate to a WDT tile index."""
    return math.floor(32 - coord / TILE_WORLD_SIZE)


def tile_origin_world(tile_min: int) -> float:
    """Return the world coordinate of the top/left edge of *tile_min*."""
    return (32 - tile_min) * TILE_WORLD_SIZE


def px_per_yard(tile_px: int = MINIMAP_TILE_PX) -> float:
    """Pixels per world yard for a stitch built at *tile_px* per tile."""
    return tile_px / TILE_WORLD_SIZE


def compute_crop_box(
    row_min: int, col_min: int,
    loc_top: float, loc_bottom: float,
    loc_left: float, loc_right: float,
    stitch_w: int, stitch_h: int,
    tile_px: int = MINIMAP_TILE_PX,
) -> tuple[tuple[int, int, int, int], tuple[float, float, float, float]]:
    """Locate a region's world rectangle inside a stitched composite.

    Returns ``(box, coverage)``:

    * ``box`` — ``(left, top, right, bottom)`` whole composite pixels,
      clamped to the composite, ready for ``Image.crop``.
    * ``coverage`` — that same box expressed as fractions
      ``(x0, y0, x1, y1)`` of the *unclamped* rectangle.

    ``coverage`` is the load-bearing half.  A world rectangle can run
    past the edge of the terrain's 64x64 tile grid — every continent map
    does, because ``UiMapAssignment`` bounds them by the art layer's
    3:2 aspect rather than by where terrain stops — and the crop then
    comes back short.  Callers must shrink the destination sub-rect by
    the same fractions; stretching a short crop across the full
    destination scales and shifts the whole map (roughly 6% of the
    layer width on Eastern Kingdoms, 7% on Kalimdor), which puts the
    art out from under the client's zone highlights.
    """
    ppyard = px_per_yard(tile_px)
    origin_x = tile_origin_world(row_min)
    origin_y = tile_origin_world(col_min)

    top = (origin_x - loc_top) * ppyard
    bottom = (origin_x - loc_bottom) * ppyard
    left = (origin_y - loc_left) * ppyard
    right = (origin_y - loc_right) * ppyard

    width = right - left
    height = bottom - top

    crop_left = int(max(0, min(round(left), stitch_w)))
    crop_right = int(max(0, min(round(right), stitch_w)))
    crop_top = int(max(0, min(round(top), stitch_h)))
    crop_bottom = int(max(0, min(round(bottom), stitch_h)))

    if width > 0 and height > 0:
        coverage = (
            (crop_left - left) / width,
            (crop_top - top) / height,
            (crop_right - left) / width,
            (crop_bottom - top) / height,
        )
    else:
        coverage = (0.0, 0.0, 1.0, 1.0)

    return (crop_left, crop_top, crop_right, crop_bottom), coverage


def grid_dims(num_tiles: int) -> tuple[int, int]:
    """Return ``(cols, rows)`` for an output tile grid with *num_tiles* slots."""
    if num_tiles == 12:
        return 4, 3
    if num_tiles == 150:
        return 15, 10
    if num_tiles == 6:
        return 3, 2
    if num_tiles == 4:
        return 2, 2
    if num_tiles == 2:
        return 2, 1
    cols = max(1, int(math.ceil(math.sqrt(num_tiles * 4 / 3))))
    rows = max(1, int(math.ceil(num_tiles / cols)))
    return cols, rows
