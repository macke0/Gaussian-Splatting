"""Baka en skanning från kommandoraden, utan att gå via HTTP.

Det snabbaste sättet att se om en skanning duger: kopiera hem rummets mapp och
kör den här. Servern gör exakt samma sak, bara med en uppladdning runt om.
"""

from __future__ import annotations

import argparse
import logging
import sys
from pathlib import Path

from .pipeline import DEFAULT_ATLAS_SIZE, DEFAULT_TARGET_FACES, bake_room


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Baka ett skannat rum.")
    parser.add_argument("directory", type=Path,
                        help="mappen med room.mesh, keyframes.json och fotona")
    parser.add_argument("--output", type=Path, default=None,
                        help="var baked.mesh och baked.png ska hamna")
    parser.add_argument("--atlas-size", type=int, default=DEFAULT_ATLAS_SIZE)
    parser.add_argument("--target-faces", type=int, default=DEFAULT_TARGET_FACES)
    arguments = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s")

    try:
        baked = bake_room(arguments.directory,
                          atlas_size=arguments.atlas_size,
                          target_faces=arguments.target_faces)
    except (FileNotFoundError, ValueError) as error:
        print(f"Gick inte att baka: {error}", file=sys.stderr)
        return 1

    baked.write(arguments.output or arguments.directory)
    print(f"{baked.triangle_count} trianglar, "
          f"{baked.seen_fraction * 100:.1f} % av ytan fotograferad")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
