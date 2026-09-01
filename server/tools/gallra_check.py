"""Hur många av de tränade gaussarna är faktiskt BESTÄMDA av fotona?

``vinkel_check`` ställer frågan om ytan: från hur många håll är rummet
fotograferat. Det här ställer den om MODELLEN: hur stor del av de gaussare vi
skickar till telefonen vilar på så få synvinklar att de är gissningar.

Skillnaden avgör om ett efterbehandlingssteg är värt att bygga. Tanken med ett
sådant steg är att gallra bort det obestämda och låta den uppmätta LiDAR-ytan
synas igenom i stället — bakgrunden ligger redan där, sju millimeter bakom
splatten, så ett hål blir solid vägg och inte svart. Men det förutsätter att det
FINNS en tydligt avgränsad population att gallra. Ligger vinkelspannet jämnt
fördelat finns ingen tröskel som skiljer luddet från resten, och då river
gallringen lika mycket bra som dåligt.

Måttet per gaussare är samma som appens ``SurfaceCoverage.spread``: största
vinkeln mellan två kameror som båda ser den, med djupkartorna som ocklusion.
Tröskeln 30° är också appens, och den kommer ur fotogrammetrin — under den är
djupet en gissning.

Talet som avgör är inte ANDELEN gaussare under tröskeln utan hur stor del av
OPACITETSMASSAN de bär. Tio procent tunna gaussare syns knappt; tio procent av
det ogenomskinliga är en vägg.

    .venv/bin/python tools/gallra_check.py <modell.ply> <skanningsmapp> \
        [--forfinade <arbetsyta>]

``--forfinade`` kör COLMAP och mäter mot de förfinade poserna. Utan den mäts en
COLMAP-tränad modell genom ARKits poser, och då hamnar kameran inne i väggen —
se fallgropen i ``splat_check``.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server import poses  # noqa: E402
from spatialfit_server.bundle import ScanBundle  # noqa: E402
from splat_check import read_ply  # noqa: E402
from vinkel_check import _seen_from, _spread  # noqa: E402

#: Så många gaussare mäts. Fördelningen står stilla långt före detta; resten är
#: bara väntetid, för varje foto projiceras mot varje punkt.
SAMPLES = 20000

#: Appens tröskel för "bestämd yta", i grader.
DETERMINED = 30.0


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]
    workspace = None
    if "--forfinade" in arguments:
        at = arguments.index("--forfinade")
        workspace = Path(arguments[at + 1])
        arguments = arguments[:at] + arguments[at + 2:]
    if len(arguments) < 2:
        print("python tools/gallra_check.py <modell.ply> <skanningsmapp> "
              "[--forfinade <arbetsyta>]", file=sys.stderr)
        return 2

    model = read_ply(Path(arguments[0]))
    room = Path(arguments[1])
    bundle = ScanBundle.load(room)
    if workspace is not None:
        refined = poses.refined(bundle, room, workspace)
        if refined is None:
            print("COLMAP löste inte poserna", file=sys.stderr)
            return 1
        bundle = refined

    generator = np.random.default_rng(0)
    index = generator.choice(len(model), min(SAMPLES, len(model)), replace=False)
    points = model.means[index].astype(np.float32)
    # Opaciteten lagras som logit i PLY:n, precis som träningen håller den.
    alpha = 1.0 / (1.0 + np.exp(-model.opacities[index]))

    directions = _seen_from(points, bundle.keyframes)
    counts = np.array([len(item) for item in directions])
    spreads = np.array([_spread(item) for item in directions])

    print(f"{len(model)} gaussare, {len(points)} mätta mot "
          f"{len(bundle.keyframes)} foton")
    print()
    mass = alpha.sum()
    for label, mask in (("inget foto ser den", counts == 0),
                        ("bara ett foto", counts == 1),
                        (f"under {DETERMINED:.0f}°", (counts >= 2) & (spreads < DETERMINED)),
                        (f"minst {DETERMINED:.0f}°", spreads >= DETERMINED)):
        print(f"  {label:<22} {mask.mean():6.1%} av antalet, "
              f"{alpha[mask].sum() / mass:6.1%} av opacitetsmassan")

    visible = spreads[counts >= 2]
    if len(visible):
        print(f"\nvinkelspann för de {len(visible)} som setts av minst två:")
        for label, value in (("p10", 10), ("median", 50), ("p90", 90)):
            print(f"  {label:<8} {np.percentile(visible, value):5.1f}°")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
