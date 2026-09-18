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


def px_per_yard() -> float:
    """Pixels per world yard at minimap resolution."""
    return MINIMAP_TILE_PX / TILE_WORLD_SIZE


def compute_crop_box(
    row_min: int, col_min: int,
    loc_top: float, loc_bottom: float,
    loc_left: float, loc_right: float,
    stitch_w: int, stitch_h: int,
) -> tuple[float, float, float, float]:
    """Compute the pixel crop box within a stitched composite.

    Returns ``(crop_left, crop_top, crop_right, crop_bottom)`` clamped
    to the composite dimensions.
    """
    ppyard = px_per_yard()
    origin_x = tile_origin_world(row_min)
    origin_y = tile_origin_world(col_min)

    crop_top = (origin_x - loc_top) * ppyard
    crop_bottom = (origin_x - loc_bottom) * ppyard
    crop_left = (origin_y - loc_left) * ppyard
    crop_right = (origin_y - loc_right) * ppyard

    crop_left = max(0, min(crop_left, stitch_w))
    crop_right = max(0, min(crop_right, stitch_w))
    crop_top = max(0, min(crop_top, stitch_h))
    crop_bottom = max(0, min(crop_bottom, stitch_h))

    return crop_left, crop_top, crop_right, crop_bottom


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
