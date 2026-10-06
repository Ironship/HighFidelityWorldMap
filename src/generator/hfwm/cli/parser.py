"""Command-line interface: argument parsing and ``--list-art-passes``."""

from __future__ import annotations

import argparse
from multiprocessing import cpu_count

from ..config.build import GAME_BUILD, GAME_PRODUCT
from ..config.paths import ORIGINAL_SUBDIR, WORLDMAP_DIR
from ..formats.wdt import MAID_FIELD_MAPTEXTURE, MAID_FIELD_MINIMAP
from ..imaging.effects import ART_PASSES


def _add_art_pass_args(parser: argparse.ArgumentParser) -> None:
    """Generate the flags for every pass in :data:`ART_PASSES`.

    Nothing here knows what any individual pass does — add one to the
    registry and its flags, help text, defaults and validation appear
    without touching this file.  ``default=None`` on the toggles is what
    lets :func:`hfwm.imaging.effects.resolve` tell "explicitly asked for" apart from
    "left at its default", which is how supersede conflicts get caught.
    """
    group = parser.add_argument_group(
        "art passes",
        "Transforms applied to the stitched art. Each is independently "
        "toggleable; --no-art-passes turns the lot off for a raw stitch.",
    )
    group.add_argument(
        "--list-art-passes",
        action="store_true",
        help="Describe every available art pass and exit",
    )
    group.add_argument(
        "--no-art-passes",
        action="store_true",
        help="Disable every art pass — the raw stitch, gaps left black",
    )
    for p in ART_PASSES:
        state = "on" if p.default else "off"
        # BooleanOptionalAction derives the --no-<name> form itself.
        group.add_argument(
            f"--{p.name}",
            dest=p.dest,
            default=None,
            action=argparse.BooleanOptionalAction,
            help=f"{p.summary} (default: {state})",
        )
        for opt in p.options:
            group.add_argument(
                f"--{p.name}-{opt.name}",
                dest=f"{p.dest}_{opt.dest}",
                metavar=opt.metavar,
                default=opt.default,
                help=f"[--{p.name}] {opt.help} (default: {opt.default})",
            )

    # Back-compat: --no-ocean-fill predates the registry and is what the
    # first ocean commit shipped.  Kept working, hidden from --help so the
    # generated --no-ocean is the one that gets discovered.
    group.add_argument(
        "--no-ocean-fill",
        dest="no_ocean_fill",
        action="store_true",
        help=argparse.SUPPRESS,
    )


def print_art_passes() -> None:
    """Long-form ``--list-art-passes`` output."""
    print("Art passes:\n")
    for p in ART_PASSES:
        print(f"  --{p.name}" + (" " * max(1, 22 - len(p.name)))
              + f"default: {'on' if p.default else 'off'}")
        print(f"      {p.summary}")
        for note in p.notes:
            print(f"      {note}")
        for opt in p.options:
            print(f"      --{p.name}-{opt.name} {opt.metavar}  "
                  f"(default: {opt.default})")
        if p.supersedes:
            print("      supersedes: "
                  + ", ".join(f"--{s}" for s in p.supersedes))
        print()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Generate high-fidelity world map textures for World of "
            f"Warcraft Forever ({GAME_PRODUCT} {GAME_BUILD}) by stitching "
            "the game's own minimap terrain tiles. Outputs uncompressed "
            "BGRA BLP2 tiles plus FDIDMap.lua."
        ),
    )
    parser.add_argument(
        "output_dir",
        nargs="?",
        default=str(WORLDMAP_DIR),
        help=f"Output directory for generated tiles (default: {WORLDMAP_DIR})",
    )
    parser.add_argument(
        "--zones",
        default=None,
        help=(
            "Comma-separated map folder names to include (default: all). "
            "Only the World and Continent maps produce art."
        ),
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Report the plan without downloading tiles or writing files",
    )
    parser.add_argument(
        "--refresh",
        action="store_true",
        help="Force re-download of the DB2 exports and zone DB",
    )
    parser.add_argument(
        "--skip-fdid-map",
        action="store_true",
        help="Skip FDIDMap.lua generation",
    )
    parser.add_argument(
        "--tables-only",
        action="store_true",
        help=(
            "Generate only the Lua metadata tables (FDIDMap.lua and "
            "CaveData.lua) without building the WorldMap art tree. "
            "Fast path for client releases."
        ),
    )
    caves = parser.add_argument_group(
        "cave map",
        "CaveData.lua — the interior (cave / dungeon) map table this "
        "build's UiMap does not carry. Art-free: it only points at "
        "FileDataIDs already in the client.",
    )
    caves.add_argument(
        "--caves",
        default=True,
        action=argparse.BooleanOptionalAction,
        help=(
            "Generate CaveData.lua so the addon's cave window has "
            "something to draw (default: on)"
        ),
    )
    caves.add_argument(
        "--caves-only",
        action="store_true",
        help=(
            "Run the cave pass alone and exit — no zone DB, no tile "
            "downloads, no BLPs. The fast way to rebuild just the "
            "interior table."
        ),
    )
    caves.add_argument(
        "--refresh-caves",
        action="store_true",
        help=(
            "Force re-download of the donor DB2 tables and re-probe every "
            "interior's art against the pinned build"
        ),
    )
    parser.add_argument(
        "--original",
        default=True,
        action=argparse.BooleanOptionalAction,
        help=(
            f"Also write a raw, art-pass-free dump to {ORIGINAL_SUBDIR}/, "
            "which backs the in-game Original background. Roughly doubles "
            "the output size and the processing time (default: on)"
        ),
    )
    parser.add_argument(
        "--threads",
        type=int,
        default=max(2, cpu_count() - 1),
        help=f"Zone processing workers (default: {max(2, cpu_count() - 1)})",
    )
    parser.add_argument(
        "--dl-threads",
        type=int,
        default=8,
        help="Parallel download threads (default: 8)",
    )
    _add_art_pass_args(parser)
    parser.add_argument(
        "--maid-field",
        type=int,
        default=MAID_FIELD_MINIMAP,
        choices=[MAID_FIELD_MAPTEXTURE, MAID_FIELD_MINIMAP],
        help=(
            f"MAID field for tile FDIDs. {MAID_FIELD_MINIMAP} = "
            f"minimapTexture (default). {MAID_FIELD_MAPTEXTURE} = "
            "mapTexture, the terrain LOD diffuse."
        ),
    )
    return parser
