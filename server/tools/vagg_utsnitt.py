"""Klipper ut samma bit SLÄT VÄGG ur foto och modeller, i full upplösning.

Korn är detalj på pixelnivå, så en nedskalad översiktsbild gömmer det — och
hela bilden går ändå inte att hämta hem från boxen. Här klipps därför bara en
ruta ut, den jämnaste i fotot, och läggs bredvid samma ruta ur varje modell.
Rutan väljs ur FOTOT så att modellen som prövas inte kan påverka valet.

    python tools/vagg_utsnitt.py <skanningsmapp> <ut.png> <modell> [...]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import synthetic_keyframes  # noqa: E402
from splat_check import read_ply, read_spz  # noqa: E402

BOX = 120
FRAME = 10


def _smoothest(grey: np.ndarray) -> tuple[int, int]:
    edges = (np.abs(np.diff(grey, axis=0)[:, :-1])
             + np.abs(np.diff(grey, axis=1)[:-1, :]))
    rows, columns = edges.shape[0] // BOX, edges.shape[1] // BOX
    tiles = edges[:rows * BOX, :columns * BOX].reshape(rows, BOX, columns, BOX)
    index = int(np.argmin(tiles.mean(axis=(1, 3))))
    return (index // columns) * BOX, (index % columns) * BOX


room, output = Path(sys.argv[1]), Path(sys.argv[2])
bundle = ScanBundle.load(room)
photo = np.asarray(bundle.keyframes[FRAME].image)
top, left = _smoothest(photo.astype(np.float32).mean(axis=2))
here = (slice(top, top + BOX), slice(left, left + BOX))

panels = [photo[here]]
for argument in sys.argv[3:]:
    path = Path(argument)
    model = read_spz(path) if path.suffix == ".spz" else read_ply(path)
    panels.append(synthetic_keyframes(model, bundle, extra_views=0)[FRAME].image[here])

strip = Image.new("RGB", (BOX * len(panels), BOX))
for column, panel in enumerate(panels):
    strip.paste(Image.fromarray(np.asarray(panel, dtype=np.uint8)), (column * BOX, 0))
strip.save(output)
print(f"ruta ({top}, {left}) ur foto {FRAME}; foto + {len(panels) - 1} modeller")
