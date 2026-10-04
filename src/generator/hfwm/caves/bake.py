"""Baking a mine's floors and rooms into BLP2 art plus the Lua values for it.

:func:`generate_mine_floors` and :func:`generate_mine_pieces` are the two
public entry points; both take a :class:`~hfwm.caves.mines.MineSpec` and
return the values to paste into CaveData.lua / FDIDMap.lua.
"""

from __future__ import annotations

from PIL import Image

from ..config.paths import WORLDMAP_DIR
from ..formats.blp import encode_blp2_bgra
from .compose import (
    MINIMAP_PX_PER_UNIT,
    build_floor_image,
    split_floors_by_height,
    world_align_rotation_degrees,
    world_to_local_projection,
)
from .fetch import fetch_group_tile, fetch_wmo_root, fetch_wmo_world_placement
from .mines import MineSpec
from .wmo import WmoGroup, parse_wmo_groups, world_z_range_for_groups


def _load_groups(spec: MineSpec) -> list[WmoGroup]:
    """Fetch *spec*'s WMO root file and parse its groups."""
    return parse_wmo_groups(fetch_wmo_root(spec.wmo_fdid), spec.tile_fdids)


def _shared_canvas(by_index: dict[int, WmoGroup], tiled_idx: list[int],
                   tiles: dict[int, Image.Image],
                   scale: float) -> tuple[float, float, int, int]:
    """Anchor and size the (pre-rotation) canvas every group is placed on.

    Returns ``(minx, maxy, canvas_w, canvas_h)``.  The canvas size is
    derived from where each tile's native-resolution rectangle actually
    lands (px0..px0+tile.width, py0..py0+tile.height), not from bbox span
    * scale — a tile's native size only approximates bbox_extent * scale
    to the nearest bake-time pixel (see MINIMAP_PX_PER_UNIT), so sizing
    the canvas off the bbox span alone can clip a tile that runs slightly
    larger than its own bbox implies.
    """
    xs = [by_index[i].bbox[0] for i in tiled_idx] + \
         [by_index[i].bbox[3] for i in tiled_idx]
    ys = [by_index[i].bbox[1] for i in tiled_idx] + \
         [by_index[i].bbox[4] for i in tiled_idx]
    minx, maxy = min(xs), max(ys)
    canvas_w = max(round((by_index[i].bbox[0] - minx) * scale) + tiles[i].width
                   for i in tiled_idx)
    canvas_h = max(round((maxy - by_index[i].bbox[4]) * scale) + tiles[i].height
                   for i in tiled_idx)
    return minx, maxy, canvas_w, canvas_h


def _pad_to_union(images: dict, fill: tuple[int, int, int, int]) -> tuple[int, int]:
    """Pad every image in *images* (in place) to the largest width/height.

    ``Image.rotate(expand=True)`` can round each rotated canvas's bounding
    box to a slightly different size even though they all started from one
    shared canvas, so this keeps the baked size single-valued.  Returns the
    common ``(width, height)``.
    """
    out_w = max(img.width for img in images.values())
    out_h = max(img.height for img in images.values())
    for key, img in images.items():
        if img.size != (out_w, out_h):
            padded = Image.new("RGBA", (out_w, out_h), fill)
            padded.paste(img, (0, 0))
            images[key] = padded
    return out_w, out_h


def _require_discovered(spec: MineSpec) -> None:
    """Fail fast, before any network call, if *spec* is still a stub.

    Raises rather than letting ``fetch_wmo_root(None)`` etc. blow up deep
    inside a confusing traceback — see ECHO_RIDGE's comment in hfwm/caves/mines.py for what
    to fill in and how.
    """
    missing = [
        field for field, value in (
            ("wmo_fdid", spec.wmo_fdid),
            ("adt_obj0_fdid", spec.adt_obj0_fdid),
            ("modf_unique_id", spec.modf_unique_id),
            ("modf_name_set", spec.modf_name_set),
        ) if value is None
    ] + (["tile_fdids"] if not spec.tile_fdids else [])
    if missing:
        raise ValueError(
            f"MineSpec {spec.key!r} is missing {', '.join(missing)} — see "
            f"the comment above its definition in hfwm/caves/mines.py for how to "
            f"look them up before generating anything for it."
        )


def generate_mine_floors(spec: MineSpec, scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Fetch, parse, composite and encode *spec*'s floor(s).

    ``scale`` is Blizzard's own fixed minimap-baking scale (px/world-unit),
    not a target size to fit — see MINIMAP_PX_PER_UNIT. The canvas is
    *derived* from it (span * scale), never chosen first and fitted to.

    Writes ``WorldMap/<spec.key>/<floor>.blp`` (``upper``/``lower`` for a
    two-floor place, just ``floor`` when ``spec.single_floor``) and returns
    the Lua fragment values (layerW/layerH/tileW/tileH/cols/rows/tiles, and
    the synthetic FDID -> relative-path pairs for FDIDMap.lua) needed to
    wire them into CaveData.lua and FDIDMap.lua.
    """
    _require_discovered(spec)
    groups = _load_groups(spec)
    by_index = {g.index: g for g in groups}

    tiled_idx = [g.index for g in groups if g.tile_fdid is not None]

    if spec.single_floor:
        floors = {"floor": sorted(tiled_idx)}
    else:
        lower_idx, upper_idx = split_floors_by_height(groups)
        floors = {"upper": upper_idx, "lower": lower_idx}

    tiles = {i: fetch_group_tile(by_index[i].tile_fdid) for i in tiled_idx}

    minx, maxy, canvas_w, canvas_h = _shared_canvas(
        by_index, tiled_idx, tiles, scale)
    # Pre-rotation canvas size, kept for the projection block below — every
    # floor shares this exact (canvas_w, canvas_h) at this point in the
    # function, before any of them get rotated/padded.
    pre_rotate_w, pre_rotate_h = canvas_w, canvas_h

    out_dir = WORLDMAP_DIR / spec.key
    out_dir.mkdir(parents=True, exist_ok=True)

    images = {
        name: build_floor_image(
            by_index, idx, tiles, minx, maxy, canvas_w, canvas_h, scale)
        for name, idx in floors.items()
    }

    # Rotate every floor into world/true-north-up orientation. Same yaw for
    # all of them: they're floor(s) of one WMO instance, placed as a unit
    # (see world_align_rotation_degrees's docstring for why this step
    # exists and where the angle comes from).
    placement = fetch_wmo_world_placement(
        spec.adt_obj0_fdid, spec.wmo_fdid, spec.modf_unique_id)
    placement_yaw = placement.rotation[1]
    rotate_angle = world_align_rotation_degrees(placement_yaw)

    # Real per-floor worldZ ranges for CaveTable.lua's floor-selection tie
    # break — see world_z_range_for_groups's docstring for why the DB2-baked
    # bounds can't provide this themselves.
    z_ranges = {
        name: world_z_range_for_groups(by_index, idx, placement)
        for name, idx in floors.items()
    }
    images = {
        name: img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 255))
        for name, img in images.items()
    }
    # expand=True can size each floor's canvas slightly differently
    # (rotating a WxH box by a non-multiple-of-90 angle rounds bounding
    # dimensions independently) even though they were built on one shared
    # WxH canvas beforehand; pad all of them to the union so layerW/layerH
    # stays single-valued, same as CaveData.lua expects one size per place.
    canvas_w, canvas_h = _pad_to_union(images, (0, 0, 0, 255))

    for name, img in images.items():
        (out_dir / f"{name}.blp").write_bytes(encode_blp2_bgra(img))

    # World<->pixel projection for CaveTable.lua's GetPlayerPosition — see
    # world_align_rotation_degrees's docstring for the rotation half of this
    # and world_to_local_projection() below for the placement half. Every
    # floor shares each of these values (same WMO instance, same composite
    # pipeline, same shared pre-rotation canvas), so this is one block at
    # the *place* level, not duplicated per floor.
    projection = world_to_local_projection(
        placement, minx, maxy, scale, pre_rotate_w, pre_rotate_h,
        rotate_angle, canvas_w, canvas_h)

    # Two floors share consecutive synthetic FDIDs starting at
    # floor_fdid_base (upper, then lower) to match how FARGODEEP_UPPER/
    # _LOWER were already laid out; a single floor just consumes the one.
    floor_names = list(floors)
    fdids = {
        name: spec.floor_fdid_base + i for i, name in enumerate(floor_names)
    }

    common = dict(layerW=canvas_w, layerH=canvas_h,
                  tileW=canvas_w, tileH=canvas_h, cols=1, rows=1)
    result = {
        name: {**common, "tiles": [fdids[name]],
               "groups": sorted(idx),
               "names": [by_index[i].name for i in sorted(idx)],
               "zMin": z_ranges[name][0], "zMax": z_ranges[name][1]}
        for name, idx in floors.items()
    }
    result["fdid_map_entries"] = {
        fdid: f"{spec.key}\\{name}" for name, fdid in fdids.items()
    }
    result["canvas"] = (canvas_w, canvas_h)
    result["projection"] = projection
    # Mirrors CaveData.lua's place-level `sharedCanvas = true`: true only
    # when there's more than one floor baked from this exact same
    # composite canvas, making them eligible for the depth-slider
    # crossfade rather than a hard swap. Always false for a single-floor
    # place — there's nothing to crossfade with. Keep this in the
    # generator so a future regen doesn't silently drop/add the flag by
    # hand in CaveData.lua.
    result["sharedCanvas"] = len(floors) > 1
    return result


def generate_mine_pieces(spec: MineSpec, scale: float = MINIMAP_PX_PER_UNIT) -> dict:
    """Bake each of *spec*'s tiled WMO groups as its own piece.

    Phase 1 baked two *floor* composites (upper.blp, lower.blp) and
    crossfaded between them as the depth slider moved. The user's Phase 2
    ask removes the floor concept from the art layer entirely: every one of
    the WMO groups that Phase 1 flattened together into those two
    composites should instead fade in and out *individually*, each on its
    own real-world-Z window, so a room's paint follows the slider on its
    own rather than in lockstep with 10+ other rooms that happen to share
    its floor label.

    The simplest correct way to get each piece positioned and rotated
    identically to how it already sits in the validated floor composite is
    to reuse that exact same pipeline per group instead of per floor:
    ``build_floor_image`` already takes an arbitrary ``group_indices``
    list (a single-group list works unchanged) and anchors that group
    against the *place's* shared ``minx``/``maxy``/``scale``/``canvas_w``/
    ``canvas_h`` — the same anchor every group already shares in
    ``generate_mine_floors``, confirmed there by both floors coming out on
    one common canvas size. Rotating each single-group canvas by the same
    ``rotate_angle`` those floors use, the same way, lands each piece's art
    at the same pixel position it already occupies inside the validated
    upper/lower composites — this is not re-derived, it is the identical
    per-group placement/rotation math generate_mine_floors already runs, just
    stopped one group early instead of compositing groups together first.

    Unlike the floor composites, each piece's canvas fills its empty area
    with full transparency (see build_floor_image's ``bg`` parameter), not
    opaque black: up to 21 of these stack on screen at once via WoW's own
    texture alpha, and an opaque-black piece would blot out every other
    piece's art already showing through underneath it. This does mean each
    piece's BLP is canvas-sized (mostly transparent) rather than tightly
    cropped to its own room — deliberately: keeping every piece anchored at
    the same (0,0) on the same shared canvas lets the renderer draw and fade
    them exactly like Phase 1 already draws/fades upper/lower, with no new
    per-piece x/y/w/h placement math in Lua at all.

    Returns the per-piece Lua fragment values (fdid, group index/name,
    zMin/zMax) plus the FDIDMap.lua entries and the shared canvas size,
    mirroring generate_mine_floors's return shape.
    """
    _require_discovered(spec)
    groups = _load_groups(spec)
    by_index = {g.index: g for g in groups}

    tiled_idx = sorted(i for i in by_index if by_index[i].tile_fdid is not None)
    tiles = {i: fetch_group_tile(by_index[i].tile_fdid) for i in tiled_idx}

    minx, maxy, canvas_w, canvas_h = _shared_canvas(
        by_index, tiled_idx, tiles, scale)

    placement = fetch_wmo_world_placement(
        spec.adt_obj0_fdid, spec.wmo_fdid, spec.modf_unique_id)
    placement_yaw = placement.rotation[1]
    rotate_angle = world_align_rotation_degrees(placement_yaw)

    out_dir = WORLDMAP_DIR / spec.key / "pieces"
    out_dir.mkdir(parents=True, exist_ok=True)

    piece_imgs: dict[int, Image.Image] = {}
    piece_z: dict[int, tuple[float, float]] = {}
    for i in tiled_idx:
        img = build_floor_image(
            by_index, [i], tiles, minx, maxy, canvas_w, canvas_h, scale,
            bg=(0, 0, 0, 0))
        img = img.rotate(rotate_angle, expand=True, fillcolor=(0, 0, 0, 0))
        piece_imgs[i] = img
        piece_z[i] = world_z_range_for_groups(by_index, [i], placement)

    # Same union-pad safety net generate_mine_floors uses: expand=True can
    # round each single-group canvas's rotated bounding box to a slightly
    # different (w, h) even though every one started from the identical
    # pre-rotation canvas size, so pad every piece to the union.
    out_w, out_h = _pad_to_union(piece_imgs, (0, 0, 0, 0))

    pieces = []
    fdid_map_entries = {}
    for order, i in enumerate(tiled_idx):
        fdid = spec.piece_fdid_base + order
        rel = f"{spec.key}\\pieces\\piece{order:02d}"
        (out_dir / f"piece{order:02d}.blp").write_bytes(
            encode_blp2_bgra(piece_imgs[i]))
        fdid_map_entries[fdid] = rel
        zmin, zmax = piece_z[i]
        pieces.append({
            "fdid": fdid, "order": order, "group": i,
            "name": by_index[i].name, "zMin": zmin, "zMax": zmax,
        })

    return {
        "pieces": pieces,
        "fdid_map_entries": fdid_map_entries,
        "canvas": (out_w, out_h),
    }
