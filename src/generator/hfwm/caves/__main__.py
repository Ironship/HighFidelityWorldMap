"""``python -m hfwm.caves [mine]`` — bake one mine and print the Lua to paste."""

from __future__ import annotations

import sys

from .bake import generate_mine_floors, generate_mine_pieces
from .mines import MINES, MineSpec


def _print_floors_result(spec: MineSpec, result: dict) -> None:
    print("canvas:", result["canvas"])
    for floor_name in [k for k in result if k not in
                        ("fdid_map_entries", "canvas", "projection", "sharedCanvas")]:
        f = result[floor_name]
        print(f"\n-- {floor_name} --")
        print(f"  groups: {f['groups']}")
        print(f"  names:  {f['names']}")
        print(f"  layerW = {f['layerW']}, layerH = {f['layerH']},")
        print(f"  tileW  = {f['tileW']}, tileH  = {f['tileH']},")
        print(f"  cols   = {f['cols']}, rows   = {f['rows']},")
        print(f"  tiles  = {{ {f['tiles'][0]} }},")
        print(f"  zMin   = {f['zMin']:.2f}, zMax   = {f['zMax']:.2f},")
    print("\n-- FDIDMap.lua entries --")
    for fdid, rel in result["fdid_map_entries"].items():
        print(f'    [{fdid}] = "{rel}",')
    p = result["projection"]
    print("\n-- projection (place-level) --")
    print(f"  minLocalX = {p['minLocalX']:.6f}, maxLocalY = {p['maxLocalY']:.6f},")
    print(f"  scale = {p['scale']},")
    print(f"  preRotW = {p['preRotW']}, preRotH = {p['preRotH']},")
    print(f"  rotateAngle = {p['rotateAngle']},")
    print(f"  rotatedW = {p['rotatedW']}, rotatedH = {p['rotatedH']},")
    print(f"  yaw = {p['yaw']},")
    print(f"  placementWorldX = {p['placementWorldX']:.6f}, placementWorldY = {p['placementWorldY']:.6f},")
    print(f"\nsharedCanvas = {result['sharedCanvas']},")


def _print_pieces_result(pieces_result: dict) -> None:
    print("\n\n== per-piece (Phase 2) ==")
    print("canvas:", pieces_result["canvas"])
    print("\n-- pieces (CaveData.lua place.pieces) --")
    for piece in pieces_result["pieces"]:
        print(f"  {{ fdid = {piece['fdid']}, group = {piece['group']}, "
              f"name = \"{piece['name']}\", "
              f"zMin = {piece['zMin']:.2f}, zMax = {piece['zMax']:.2f} }},")
    print("\n-- FDIDMap.lua entries (pieces) --")
    for fdid, rel in pieces_result["fdid_map_entries"].items():
        print(f'    [{fdid}] = "{rel}",')
    pw, ph = pieces_result["canvas"]
    print(f"\npieceCanvasW = {pw}, pieceCanvasH = {ph},")


def main() -> None:
    key = sys.argv[1] if len(sys.argv) > 1 else "fargodeep"
    if key not in MINES:
        print(f"Unknown mine {key!r}. Known: {', '.join(MINES)}", file=sys.stderr)
        sys.exit(2)
    spec = MINES[key]

    try:
        floors_result = generate_mine_floors(spec)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    _print_floors_result(spec, floors_result)

    pieces_result = generate_mine_pieces(spec)
    _print_pieces_result(pieces_result)


if __name__ == "__main__":
    main()
