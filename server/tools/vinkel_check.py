"""Från hur många HÅLL är varje yta i rummet sedd?

``coverage_check`` svarar på var det finns mätt yta. Det här svarar på något
annat: hur många skilda RIKTNINGAR ytan är fotograferad från. Skillnaden syns
först när man vrider på splatten.

En gaussare som bara setts från ett håll är obestämd i två av tre led. Den kan
vara en skiva vänd mot kameran eller en nål på tvären, och båda återger fotot
lika bra — ingenting i förlusten skiljer dem åt. Först ett andra foto från en
annan vinkel avgör saken. Därför gäller: en yta sedd inom en smal vinkelkon är
inte rekonstruerad, den är MÅLAD, och den faller isär så fort betraktaren rör
sig utanför konen.

Talet att läsa är vinkelspannet: den största vinkeln mellan två kameror som
båda ser punkten. Tumregler ur fotogrammetrin:

    <10°   en enda synvinkel i praktiken — djupet är en gissning
    10–30° svagt men användbart
    >30°   ytan är bestämd

Är MEDIANEN under tio grader är det inte träningen som binder utan gången genom
rummet: kunden har gått förbi väggen i stället för runt föremålen, och då finns
skärpan bara längs den bana kameran faktiskt tog.

    .venv/bin/python tools/vinkel_check.py <skanningsmapp>
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle, connected_surface  # noqa: E402

#: Så många ytpunkter mäts. Fler ändrar inte fördelningen, bara väntetiden.
SAMPLES = 4000

#: Hur långt ifrån djupkartans yta en punkt får ligga och ändå räknas som sedd.
#: Samma marginal som frirymdskarvningen använder, och av samma skäl: under den
#: är det mätbrus, över den är det en annan yta.
MARGIN = 0.05


def _seen_from(points: np.ndarray, keyframes) -> list[np.ndarray]:
    """Enhetsvektorn från varje punkt till de kameror som faktiskt ser den."""
    directions: list[list[np.ndarray]] = [[] for _ in points]

    for keyframe in keyframes:
        if keyframe.depth is None:
            continue
        height, width = keyframe.depth.shape
        pixels, distance = keyframe.project(points)

        scale = np.array([width, height]) / keyframe.image_size
        with np.errstate(invalid="ignore"):
            grid = np.nan_to_num(pixels * scale, nan=-1.0,
                                 posinf=-1.0, neginf=-1.0).astype(np.int64)

        inside = ((distance > 0.05) & (grid[:, 0] >= 0) & (grid[:, 0] < width)
                  & (grid[:, 1] >= 0) & (grid[:, 1] < height))
        index = np.nonzero(inside)[0]
        if len(index) == 0:
            continue

        # Bara punkter som djupkartan bekräftar: en punkt bakom en vägg syns i
        # bildrutan men är skymd, och en skymd yta är inte fotograferad.
        seen = keyframe.depth[grid[index, 1], grid[index, 0]]
        index = index[np.abs(seen - distance[index]) <= MARGIN]

        # Kameran står i kolumn fyra av det inverterade läget.
        eye = -keyframe.camera_from_world[:3, :3].T @ keyframe.camera_from_world[:3, 3]
        for point in index:
            offset = eye - points[point]
            length = np.linalg.norm(offset)
            if length > 1e-6:
                directions[point].append(offset / length)

    return [np.array(item) for item in directions]


def _spread(directions: np.ndarray) -> float:
    """Största vinkeln i grader mellan två av riktningarna."""
    if len(directions) < 2:
        return 0.0
    # Punktprodukten mellan alla par; den minsta är det största spannet.
    smallest = (directions @ directions.T).min()
    return float(np.degrees(np.arccos(np.clip(smallest, -1.0, 1.0))))


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]
    if not arguments:
        print("python tools/vinkel_check.py <skanningsmapp>", file=sys.stderr)
        return 2

    bundle = ScanBundle.load(Path(arguments[0]))
    surface, _ = connected_surface(bundle.mesh)

    generator = np.random.default_rng(0)
    chosen = surface[generator.choice(len(surface),
                                      min(SAMPLES, len(surface)), replace=False)]

    directions = _seen_from(chosen.astype(np.float32), bundle.keyframes)
    counts = np.array([len(item) for item in directions])
    spreads = np.array([_spread(item) for item in directions])

    print(f"{len(chosen)} ytpunkter mot {len(bundle.keyframes)} foton")
    print(f"  aldrig sedda      {(counts == 0).mean():6.1%}")
    print(f"  sedda av ett foto {(counts == 1).mean():6.1%}")
    print(f"  foton per punkt   median {np.median(counts):.0f}")

    # Punkter ingen ser har inget vinkelspann och skulle dra medianen till noll
    # av fel skäl — de är ett täckningsfel, inte ett vinkelfel.
    visible = spreads[counts >= 2]
    print(f"\nvinkelspann för de {len(visible)} punkter som setts av minst två:")
    for label, value in (("p10", 10), ("median", 50), ("p90", 90)):
        print(f"  {label:<8} {np.percentile(visible, value):5.1f}°")
    for limit in (10, 30):
        print(f"  under {limit}° {(visible < limit).mean():6.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
