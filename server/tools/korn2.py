"""Skiljer korn från sudd, vilket skärpetalet inte kan.

Skärpan är kantstyrka delad med fotots, och två motsatta fel höjer respektive
sänker den: dis suddar kanterna, korn hittar på kanter som inte finns. Därför är
103 % inte bättre än 90 % utan sämre, och talet ensamt kan inte säga vilket fel
som råder.

Det här måttet frågar i stället på en yta där fotot självt är JÄMNT: hur mycket
skiftar renderingen lokalt jämfört med fotot? Under ett betyder slätare än
verkligheten, alltså sudd. Över ett betyder att modellen lagt till struktur som
inte finns, alltså korn.

Rutorna väljs ur fotot, aldrig ur renderingen, så valet inte kan färgas av vilken
modell som mäts. Mätt på var tionde foto, samma undanhållna urval som
``splat_check.py``.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import synthetic_keyframes  # noqa: E402
from splat_check import read_ply, read_spz  # noqa: E402

BOX = 48       # rutans sida i pixlar
PATCHES = 12   # så många släta rutor per foto


def _grey(image: np.ndarray) -> np.ndarray:
    return np.asarray(image, dtype=np.float32).mean(axis=2)


def _smooth_boxes(photo: np.ndarray) -> list[tuple[int, int]]:
    """De jämnaste rutorna i fotot, utan överlapp."""
    edges = (np.abs(np.diff(photo, axis=0)[:, :-1])
             + np.abs(np.diff(photo, axis=1)[:-1, :]))
    height, width = edges.shape
    rows, columns = height // BOX, width // BOX
    tiles = edges[:rows * BOX, :columns * BOX].reshape(rows, BOX, columns, BOX)
    strength = tiles.mean(axis=(1, 3))
    order = np.argsort(strength, axis=None)[:PATCHES]
    return [(int(index // columns) * BOX, int(index % columns) * BOX) for index in order]


room = Path(sys.argv[1])
bundle = ScanBundle.load(room)
held_out = list(range(0, len(bundle.keyframes), 10))

print(f"{'modell':<20} {'lokal spridning mot fotots':>28}")
for argument in sys.argv[2:]:
    path = Path(argument)
    # Väljer på filändelsen som de andra måtten. En tränad modell skrivs som PLY
    # av `train_splat`; bara det som skickats till telefonen är SPZ.
    model = read_spz(path) if path.suffix == ".spz" else read_ply(path)
    views = synthetic_keyframes(model, bundle, extra_views=0)
    ratios = []
    for index in held_out:
        rendered = _grey(views[index].image)
        photo = np.asarray(bundle.keyframes[index].image)
        if photo.shape[:2] != rendered.shape:
            from PIL import Image
            photo = np.asarray(Image.fromarray(photo).resize(
                (rendered.shape[1], rendered.shape[0])))
        photo = _grey(photo)
        for top, left in _smooth_boxes(photo):
            here = (slice(top, top + BOX), slice(left, left + BOX))
            # Spridningen mäts kring det lokala medelvärdet, så en ren
            # ljusskillnad mellan modell och foto inte räknas som struktur.
            ratios.append(float(rendered[here].std()) / max(float(photo[here].std()), 1e-6))
    print(f"{path.name:<20} {np.median(ratios):>27.2f}x")
