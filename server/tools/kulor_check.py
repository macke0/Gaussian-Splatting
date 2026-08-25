"""Är fläckarna på väggen ljushet eller KULÖR?

Bilden visar pastellrosa, grönt och blått på en vägg som i fotot är jämngrå.
Skillnaden spelar roll för vad felet är: skiftande ljushet vore geometri eller
skuggor, medan skiftande kulör bara kan komma ur gaussarnas egen färg — och den
är tre fria tal per gaussare utan något som säger att två grannar på samma vägg
ska ha samma nyans.

Måttet är spridningen i färgskillnaderna (röd minus grön, blå minus grön), som
är noll för allt grått oavsett hur ljust det är. Rutorna väljs ur fotot.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle
from spatialfit_server.splat import synthetic_keyframes
from splat_check import read_ply, read_spz

BOX = 48
PATCHES = 12


def _boxes(grey: np.ndarray) -> list[tuple[int, int]]:
    edges = (np.abs(np.diff(grey, axis=0)[:, :-1])
             + np.abs(np.diff(grey, axis=1)[:-1, :]))
    rows, columns = edges.shape[0] // BOX, edges.shape[1] // BOX
    tiles = edges[:rows * BOX, :columns * BOX].reshape(rows, BOX, columns, BOX)
    order = np.argsort(tiles.mean(axis=(1, 3)), axis=None)[:PATCHES]
    return [(int(i // columns) * BOX, int(i % columns) * BOX) for i in order]


def _chroma(patch: np.ndarray) -> float:
    """Spridningen i kulör, oberoende av ljushet."""
    patch = patch.astype(np.float32)
    return float(np.hypot((patch[..., 0] - patch[..., 1]).std(),
                          (patch[..., 2] - patch[..., 1]).std()))


room = Path(sys.argv[1])
bundle = ScanBundle.load(room)
held_out = list(range(0, len(bundle.keyframes), 10))

print(f"{'modell':<20} {'kulörspridning':>15} {'fotots':>8} {'kvot':>6}")
for argument in sys.argv[2:]:
    path = Path(argument)
    # Väljer på filändelsen som de andra måtten: `train_splat` skriver PLY, och
    # bara det som skickats till telefonen är SPZ.
    model = read_spz(path) if path.suffix == ".spz" else read_ply(path)
    views = synthetic_keyframes(model, bundle, extra_views=0)
    ours, theirs = [], []
    for index in held_out:
        rendered = views[index].image
        photo = np.asarray(bundle.keyframes[index].image)
        if photo.shape[:2] != rendered.shape[:2]:
            from PIL import Image
            photo = np.asarray(Image.fromarray(photo).resize(
                (rendered.shape[1], rendered.shape[0])))
        for top, left in _boxes(photo.astype(np.float32).mean(axis=2)):
            here = (slice(top, top + BOX), slice(left, left + BOX))
            ours.append(_chroma(rendered[here]))
            theirs.append(_chroma(photo[here]))
    ours, theirs = np.median(ours), np.median(theirs)
    print(f"{path.name:<20} {ours:>15.2f} {theirs:>8.2f} {ours / theirs:>5.1f}x")
