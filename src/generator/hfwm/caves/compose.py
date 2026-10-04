"""Compositing and projection for baked indoor floor plans.

Pure image and coordinate maths — placing each WMO group's minimap tile
on a shared canvas, turning that canvas north-up, and baking the constants
the addon needs to put the player pin on it.  No fetching, no files.
"""

from __future__ import annotations

from PIL import Image

from ..config.tiles import TILE_WORLD_SIZE
from .wmo import WmoGroup, WmoPlacement


def split_floors_by_height(groups: list[WmoGroup]) -> tuple[list[int], list[int]]:
    """Split tiled groups into two floors by 1D 2-means on Z-midpoint.

    Interior WMOs carry no per-floor tag anywhere in the file — the source
    DB2 rows (WMOAreaTable) don't distinguish floors within one NameSetID
    either. The groups themselves cluster into two bands (a "mine shaft"
    cluster and a "surface level" cluster), which is what a real two-storey
    mine looks like from its geometry alone. 2-means recovers that split
    without hand-picking a threshold; the simpler "largest gap between
    consecutive Z-midpoints" was tried first and picked the wrong boundary
    here — Fargodeep's tallest single room (``mine06``, z-mid 13.5) sits far
    enough above its own cluster that the widest gap isolated it alone
    rather than falling at the real floor boundary. 2-means is not fooled by
    that because it minimises total within-cluster spread, not the gap on
    either side of one point.

    Returns (lower_indices, upper_indices).
    """
    tiled = [g for g in groups if g.tile_fdid is not None]
    zmids = [((g.bbox[2] + g.bbox[5]) / 2, g.index) for g in tiled]

    c1, c2 = min(z for z, _ in zmids), max(z for z, _ in zmids)
    lower, upper = [], []
    for _ in range(100):
        lower = [(z, i) for z, i in zmids if abs(z - c1) <= abs(z - c2)]
        upper = [(z, i) for z, i in zmids if abs(z - c1) > abs(z - c2)]
        if not lower or not upper:
            break
        new_c1 = sum(z for z, _ in lower) / len(lower)
        new_c2 = sum(z for z, _ in upper) / len(upper)
        if (new_c1, new_c2) == (c1, c2):
            break
        c1, c2 = new_c1, new_c2

    return [i for _, i in lower], [i for _, i in upper]


# Pixels-per-world-unit for indoor WMO group minimap tiles, and the
# vertical-axis convention to place them with. Neither is a fitted/guessed
# value anymore — both come from reading real, shipped code that solves
# this exact problem (stitching WMO-group minimap tiles for a dungeon,
# including classic instances like Ragefire Chasm, structurally identical
# to Fargodeep Mine):
#
#   * Cal Henderson's World of MapCraft (github.com/iamcal/World-of-MapCraft,
#     build/wmo_build.php) is a real, shipped project that built exactly
#     this kind of stitched instance map for every WoW dungeon/raid,
#     including classic ones. Its build_wmo_map() scales MOGI X/Y by a
#     hardcoded ``1.993`` (comment: "need to double chunk coords") — i.e.
#     the same ~2px/unit convention, refined to a more precise constant.
#   * Critically, extract_mogi() negates the local Y coordinate before use
#     (``0 - $box[2]``, ``0 - $box[5]``) and the group's *own tile height*
#     is then subtracted from that negated-and-scaled value to anchor the
#     group's top-left corner. Un-negated, my first attempt at this mapped
#     column<-X/row<-Y directly, which gets width/height and touching-ness
#     right (bbox aspect ratio matches tile aspect ratio either way) but
#     silently mirrors the whole floor plan north-south, since increasing
#     world Y was mapped to increasing row instead of decreasing row.
#   * Marlamin's WoWTools.MinimapCompileWMO (github.com/Marlamin/
#     WoWTools.Minimaps, Program.cs) independently confirms the ~2px/unit
#     scale (``BoundingBox.Minimum.{X,Y} * 2``) and that tiles are blitted
#     at *native* resolution with zero resampling — never resized to fit a
#     target canvas.
#   * Measuring pixel-size / bbox-extent across Fargodeep's own 21 tiles
#     gives 1.78-2.01 px/unit, clustering tightly on ~1.99 — matching
#     World of MapCraft's 1.993 almost exactly, independently.
#   * wowdev.wiki/WMO's MOGI section confirms there's no separate
#     placement/rotation record to look up at all: "Groups don't have
#     placement or orientation information, because the coordinates ...
#     are already correctly transformed relative to (0,0,0)".
#
# So: bbox is placement (no rotation/skew), scale is a fixed 1.993 (not
# fitted per-floor), and the row axis is anchored from each group's
# *maximum* Y (north edge) against the floor's global maximum Y, mirroring
# extract_mogi()'s negate-then-anchor-from-top behaviour exactly.
MINIMAP_PX_PER_UNIT = 1.993


def build_floor_image(groups_by_index: dict[int, WmoGroup],
                       group_indices: list[int],
                       tiles: dict[int, Image.Image],
                       minx: float, maxy: float,
                       canvas_w: int, canvas_h: int,
                       scale: float = MINIMAP_PX_PER_UNIT,
                       bg: tuple[int, int, int, int] = (0, 0, 0, 255)) -> Image.Image:
    """Composite one floor's (or one piece's) groups onto a shared-scale canvas.

    Screen axis mapping: canvas column <- WMO-local X (unflipped), canvas
    row <- WMO-local Y *negated* (north/max-Y renders at the top, i.e. row
    0). See MINIMAP_PX_PER_UNIT's docstring: World of MapCraft's real,
    shipped extract_mogi()/build_wmo_map() negates Y before placing tiles;
    without that flip, width/height and touching-ness both look right
    (aspect ratios match, gaps are zero) but the whole floor plan comes out
    mirrored north-south. Column still anchors off each group's own
    *minimum* X against the floor's global minimum X; row anchors off each
    group's own *maximum* Y (its north edge) against the floor's global
    maximum Y — the mirrored equivalent of the X anchor, per extract_mogi.

    Each tile is pasted at its *native* pixel resolution — no per-tile
    resize. Blizzard's own compiler and World of MapCraft both draw a
    group's tile 1:1 at the fixed scale and size the canvas around that,
    never the other way around; resizing tiles to fit an arbitrarily-chosen
    canvas size was this script's original, wrong approach.

    ``bg`` defaults to opaque black — right for a full floor image, which is
    meant to be the only thing on screen at its sublevel and should paint
    over whatever's behind it where it has no room art. Phase 2's per-piece
    images are the opposite: many of them stack on the same sublevel range
    at once (see generate_mine_pieces), so each one's "no room here"
    area must stay fully transparent (bg=(0,0,0,0)) or it would blot out
    every other piece already composited underneath it.
    """
    canvas = Image.new("RGBA", (canvas_w, canvas_h), bg)
    for idx in group_indices:
        g = groups_by_index[idx]
        x1, _, _, _, y2, _ = g.bbox
        tile = tiles[idx]
        px = round((x1 - minx) * scale)
        py = round((maxy - y2) * scale)
        canvas.alpha_composite(tile, (px, py))
    return canvas


def world_align_rotation_degrees(placement_yaw_degrees: float) -> float:
    """PIL ``Image.rotate()`` angle (CCW-positive) that turns a
    ``build_floor_image()`` canvas from WMO-group-local orientation into
    world/true-north-up orientation, given the WMO instance's MODF
    ``rotation.y`` (degrees).

    Why this is needed at all: ``build_floor_image()`` places tiles using
    each group's own MOGI bounding box, which is in the *WMO's own local
    model space* — correct for every fix so far, because Marlamin's
    compiler and World of MapCraft both build that same local-space image
    and stop there. But those two tools are solving a different problem
    than this one: they bake either a standalone WMO asset (no placement
    at all) or a *dungeon-only* WDT's instance WMO (placed at a fixed,
    always-zero rotation by convention, since an instance has no outdoor
    terrain to be misaligned with). Fargodeep Mine is a real open-world
    micro-dungeon: its WMO is placed into Dun Morogh's terrain with a
    real, non-zero MODF rotation (301.5 degrees — see
    ``fetch_wmo_world_placement``), and unlike the small minimap widget (which
    rotates freely with the player's facing, so a WMO-local-space image is
    fine there), the World Map this addon draws over is always north-up.
    Composited-but-unrotated, Fargodeep's floor plan is turned exactly as
    far from north-up as its placement is turned from identity — which is
    what the user is seeing when they say the cave's orientation is wrong.

    Derivation (no shipped tool does this step, so this one is worked from
    wowdev.wiki/ADT/v18's own coordinate-system table rather than fitted):

      * "M2/WMO (Models)" axes: local +X = South, local +Y = East. MOGI
        bounding boxes are in this space, so a group's local (x, y) is
        world-relative (South, East) = (x, y) *before* placement rotation.
      * "MDDF/MODF (Placement)" row: "Rotation y: around Up axis" — i.e.
        ``rotation.y`` is precisely the yaw applied about the vertical
        axis when placing the model into the world, in a right-handed
        sense (the same table's "for LH renderers, all rotations have to
        be negated" note is a caveat for the *other* case, not this one).
        A right-handed yaw about Up rotates East *towards* North for
        positive angle (Up = East x North).
      * ``build_floor_image`` already maps canvas column <- local X,
        canvas row <- -(local Y) (see its own docstring). Composing that
        fixed mapping with the placement rotation and solving for the
        pure-2D transform from (column, row) to a north-up map (column <-
        world East, row <- -world North) collapses to a single rotation:
        world-up-map angle = 90 - rotation.y, applied *clockwise* to the
        pixel grid (a rotation matrix applied directly to row-down pixel
        coordinates is clockwise for a positive angle, not counter-
        clockwise, because the row axis is flipped relative to the
        right-handed math the matrix assumes).
      * ``Image.rotate()`` is counter-clockwise-positive, so negate:
        PIL angle = rotation.y - 90.

    This is the one step in the whole pipeline that isn't cross-checked
    against a second independent shipped implementation the way the
    placement/scale fix was (nothing else stitches an open-world WMO cave
    onto a north-up world map), so it should be treated as the first
    thing to double check in-game: if the cave's orientation still looks
    wrong, flipping the sign here (``90 - rotation.y`` instead of
    ``rotation.y - 90``) is the first thing to try.
    """
    return placement_yaw_degrees - 90.0


def world_to_local_projection(placement: WmoPlacement,
                               min_local_x: float, max_local_y: float,
                               scale: float,
                               pre_rotate_w: int, pre_rotate_h: int,
                               rotate_angle_degrees: float,
                               rotated_w: int, rotated_h: int) -> dict:
    """The constants ``CaveTable:GetPlayerPosition`` needs to place the
    player pin on Fargodeep's rotated, WMO-local-coordinate art, baked once
    here rather than re-derived in Lua at runtime.

    Two transforms chain together, both already exercised elsewhere in this
    file and cross-checked against data this project independently trusts
    (the same standard used for ``world_z_range_for_groups``'s height fix):

    1. World -> WMO-local (X, Y). This is ``world_z_range_for_groups``'s
       horizontal-plane counterpart: that function converts local Z to
       world Z with a pure offset (yaw never changes height); this is the
       remaining rotation for the horizontal plane. Forward direction
       (local -> world), combining the M2/WMO local-axis convention (local
       +X = South, local +Y = East) with a right-handed yaw about Up
       (``world_align_rotation_degrees``'s "East towards North" fact) and
       the MODF raw-field convention already validated for height:

           northOffset = -localX * cos(yaw) + localY * sin(yaw)
           eastOffset  =  localX * sin(yaw) + localY * cos(yaw)
           worldX = placementWorldX + northOffset   -- north component
           worldY = placementWorldY - eastOffset     -- west component

       where ``placementWorldX = 32*TILESIZE - placement.position.z`` and
       ``placementWorldY = 32*TILESIZE - placement.position.x`` (the same
       raw-x/raw-z -> world horizontal-axis correction already validated in
       ``world_z_range_for_groups``'s docstring). The 2x2 matrix this
       represents is its own inverse (determinant -1, and squares to
       identity), so the world -> local direction baked here reuses the
       same cos/sin terms:

           localX = -northOffset * cos(yaw) + eastOffset * sin(yaw)
           localY =  northOffset * sin(yaw) + eastOffset * cos(yaw)

       Validated in this session two ways: (a) transforming every one of
       Fargodeep's 21 WMO groups' bbox corners through the forward
       transform lands their world-space bounding box at
       X in [-9870.7, -9711.2], Y in [63.9, 215.9] — inside
       CaveData.lua's already-trusted place ``bounds`` of
       {-9880, -9700, 34.25, 289.25} in both axes, exactly as expected
       for a WMO's own geometric footprint sitting inside the DB2 area's
       (necessarily coarser) bounding rectangle; (b) a local -> world ->
       local round trip over the same 21 corners is exact (0.000000 unit
       error), confirming the inverse is algebraically correct, not just
       plausible.

    2. WMO-local (X, Y) -> baked pixel. This is exactly
       ``build_floor_image``'s own per-group placement formula
       (``px = (x - minLocalX) * scale``, ``py = (maxLocalY - y) * scale``)
       generalised from a group anchor to any point, followed by the same
       ``Image.rotate(angle, expand=True)`` pixel transform already
       empirically validated against Pillow's real behaviour elsewhere in
       this project (rotate about the pre-rotation image's own center,
       re-center in the larger post-rotation canvas). Re-validated here at
       Fargodeep's actual dimensions (348x257 -> 432x401 at 211.5 degrees)
       against real marked-pixel round trips through Pillow, matching to
       within ~1px (antialiasing) on every test point.

    Both floors share every value here — same WMO instance, same
    placement, same shared pre-rotation canvas — so this is computed once
    and stored at the *place* level in CaveData.lua, not per floor.
    """
    px, py, pz = placement.position
    yaw = placement.rotation[1]
    tilesize = TILE_WORLD_SIZE
    placement_world_x = 32 * tilesize - pz
    placement_world_y = 32 * tilesize - px
    return {
        "minLocalX": min_local_x,
        "maxLocalY": max_local_y,
        "scale": scale,
        "preRotW": pre_rotate_w,
        "preRotH": pre_rotate_h,
        "rotateAngle": rotate_angle_degrees,
        "rotatedW": rotated_w,
        "rotatedH": rotated_h,
        "yaw": yaw,
        "placementWorldX": placement_world_x,
        "placementWorldY": placement_world_y,
    }
