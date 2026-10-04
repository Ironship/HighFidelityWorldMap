#!/usr/bin/env python3
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DESCRIPTION_PATH = REPO_ROOT / "docs" / "DESCRIPTION.md"
BUILDING_PATH = REPO_ROOT / "docs" / "BUILDING.md"
README_PATH = REPO_ROOT / "README.md"


def read_text(path: Path) -> str:
    if not path.exists():
        raise FileNotFoundError(f"Missing required source file: {path}")
    return path.read_text(encoding="utf-8").rstrip()


def main() -> None:
    description = read_text(DESCRIPTION_PATH)
    building = read_text(BUILDING_PATH)
    README_PATH.write_text(f"{description}\n\n{building}\n", encoding="utf-8")


if __name__ == "__main__":
    main()
