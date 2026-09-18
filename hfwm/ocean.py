"""Ocean unification — one sea colour instead of three.

The stitched minimap shows the sea in three different ways, and where they
meet the result is a set of hard rectangular seams on 533-yard tile
boundaries:

1. **Open-ocean tiles** — an ADT with no terrain in it bakes a flat, almost
   black ``(8, 16, 16)`` fill across the whole 512px minimap tile.
2. **Coastal tiles** — an ADT that does contain terrain renders its water
   surface through the normal water shader, giving the noticeably lighter
   ``(26, 50, 69)``.  So every coast has a light shelf abruptly bounded by
   dark open ocean one tile out.
3. **Cells with no tile at all** — the WDT's MAID grid only covers ADTs
   that exist, so past the edge of the terrain grid there is nothing, and
   the stitch canvas's own black shows through.  On Eastern Kingdoms that
   is 74% of the art layer.

This module collapses all three onto a single colour.  Two passes:

* :func:`unify_tile` rewrites every ocean-palette pixel in a source tile.
  It runs at the tile's **native resolution, before the downscale** to the
  region's stitch resolution — do it after and the downscale has already
  blended dark ocean into light across every coast tile, leaving a fringe
  no exact-colour match can reach.
* :func:`classify_missing_cells` decides what the empty cells become.
  Filling them unconditionally would be wrong: an interior instance map
  like Alterac Valley bakes its own neutral grey void into its tiles, and
  painting the surrounding empty cells blue just moves the seam.  So empty
  cells are grouped into 4-connected components over the region's WDT grid
  and a component is only filled if it actually touches a mostly-ocean
  tile.  AV's void has no ocean neighbour and stays black; a hole in the
  middle of a landmass stays black; the sea around a continent or an island
  fills.

Both passes are keyed off a small measured palette rather than a
"looks blue" heuristic, because the fills are flat and exact and a loose
test eats dark coastal cliff shadow.  Inland lakes use the water shader at
their own tint and are not in the palette, so they survive untouched.
"""

from __future__ import annotations

from collections import deque

from .constants import OCEAN_FILL_COLORS, OCEAN_FILL_TOLERANCE, OCEAN_TILE_FRACTION


# ---------------------------------------------------------------------------
# Colour parsing
# ---------------------------------------------------------------------------

def parse_rgb(value: str) -> tuple[int, int, int]:
    """Parse ``#RRGGBB`` / ``RRGGBB`` / ``R,G,B`` into an RGB triple."""
    text = value.strip()
    if "," in text:
        parts = [p.strip() for p in text.split(",")]
        if len(parts) != 3:
            raise ValueError(f"expected 3 comma-separated channels, got {value!r}")
        rgb = tuple(int(p) for p in parts)
    else:
        hexpart = text[1:] if text.startswith("#") else text
        if len(hexpart) != 6:
            raise ValueError(f"expected 6 hex digits, got {value!r}")
        rgb = tuple(int(hexpart[i:i + 2], 16) for i in (0, 2, 4))

    if any(c < 0 or c > 255 for c in rgb):
        raise ValueError(f"channels must be 0-255, got {value!r}")
    return rgb  # type: ignore[return-value]


# ---------------------------------------------------------------------------
# Pixel pass
# ---------------------------------------------------------------------------

def ocean_mask(rgb):
    """Return a bool mask of ocean-fill pixels in an ``HxWx3`` array.

    Matches any colour in :data:`OCEAN_FILL_COLORS` within
    :data:`OCEAN_FILL_TOLERANCE` per channel (Chebyshev distance).

    Pure black is deliberately *not* matched.  It looks like a "no data"
    fill and it is tempting to sweep it in here, but inside a tile that
    has loaded it is mostly sparse inland speckle — across Eastern
    Kingdoms' 736 source tiles it is 6595 pixels, 0.003%, and four
    fifths of that is in tiles with no sea in them at all.  Matching it
    bought nothing and cost correctness: it put blue dots into interior
    maps like Alterac Valley that have no ocean anywhere near them.  The
    black that actually matters is whole cells the WDT never had a tile
    for, and :func:`classify_missing_cells` handles those with the
    context to know whether they are sea.
    """
    import numpy as np

    rgb = rgb.astype(np.int16, copy=False)
    mask = np.zeros(rgb.shape[:2], dtype=bool)
    for color in OCEAN_FILL_COLORS:
        delta = np.abs(rgb - np.array(color, dtype=np.int16)).max(axis=2)
        mask |= delta <= OCEAN_FILL_TOLERANCE
    return mask


def unify_tile(img, ocean_rgb: tuple[int, int, int]) -> tuple[object, float]:
    """Recolour every ocean-fill pixel of *img* to *ocean_rgb*.

    Returns ``(image, ocean_fraction)``.  *img* is an RGBA PIL image at its
    native resolution; the returned image is a new one.  ``ocean_fraction``
    is what share of the tile was sea, which
    :func:`classify_missing_cells` uses to tell open water apart from an
    interior map's void.
    """
    import numpy as np
    from PIL import Image

    arr = np.array(img)
    mask = ocean_mask(arr[:, :, :3])
    frac = float(mask.mean())
    if frac:
        arr[:, :, :3][mask] = ocean_rgb
        img = Image.fromarray(arr)
    return img, frac


# ---------------------------------------------------------------------------
# Empty-cell pass
# ---------------------------------------------------------------------------

def classify_missing_cells(
    ocean_fracs: dict[tuple[int, int], float],
    row_min: int,
    row_max: int,
    col_min: int,
    col_max: int,
    tile_fraction: float = OCEAN_TILE_FRACTION,
) -> list[tuple[int, int]]:
    """Return the empty ``(row, col)`` cells that should be filled with sea.

    *ocean_fracs* maps every cell that produced a tile to that tile's ocean
    fraction; any cell in the region's grid that is absent from it is empty.
    Empty cells are grouped into 4-connected components, and a component is
    returned only if at least one of its neighbours is a tile whose ocean
    fraction reaches *tile_fraction* — i.e. the gap opens onto real water,
    not onto the grey void of an interior map or the middle of a landmass.
    """
    grid_rows = range(row_min, row_max + 1)
    grid_cols = range(col_min, col_max + 1)

    empty = {
        (r, c)
        for r in grid_rows
        for c in grid_cols
        if (r, c) not in ocean_fracs
    }
    if not empty:
        return []

    oceanic = {
        cell for cell, frac in ocean_fracs.items() if frac >= tile_fraction
    }
    if not oceanic:
        # Nothing in this region reads as open water, so there is no sea to
        # extend into the gaps.  Leave them black.
        return []

    fill: list[tuple[int, int]] = []
    unvisited = set(empty)
    while unvisited:
        seed = unvisited.pop()
        component = [seed]
        touches_ocean = False
        queue = deque([seed])
        while queue:
            r, c = queue.popleft()
            for nr, nc in ((r - 1, c), (r + 1, c), (r, c - 1), (r, c + 1)):
                if (nr, nc) in oceanic:
                    touches_ocean = True
                    continue
                if (nr, nc) in unvisited:
                    unvisited.discard((nr, nc))
                    component.append((nr, nc))
                    queue.append((nr, nc))
        if touches_ocean:
            fill.extend(component)

    return fill
