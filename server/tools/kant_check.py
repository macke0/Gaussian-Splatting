"""Mäter skärpan DÄR DET FINNS KANTER, vilket skärpetalet inte gör.

``splat_check`` delar renderingens kantstyrka med fotots över hela bilden, och
``korn2`` frågar hur mycket modellen skiftar där fotot är jämnt. Ingen av dem kan
avslöja den kombination som är värst: en rendering som tappat de riktiga kanterna
men gnistrar överallt. Kornet lägger till kantenergi ungefär lika mycket i varje
ruta, så det kan lyfta ett globalt skärpetal till hundra procent samtidigt som
varenda verklig kant är utsmetad. Ett rum kan alltså mäta 103 % och ändå se
suddigt ut, och det är precis vad användaren rapporterat.

Måttet här väljer i stället de rutor där FOTOT har starkast kanter och jämför bara
dem. I en sådan ruta är fotots egen kantenergi stor, så kornets bidrag drunknar i
den och kvoten säger något om de riktiga kanterna. Under ett betyder utsmetat.

Rutorna väljs ur fotot, aldrig ur renderingen, precis som i ``korn2`` — annars
kunde valet färgas av vilken modell som mäts. Mätt på var tionde foto, samma
undanhållna urval som ``splat_check``.

Läs talet TILLSAMMANS med ``korn2``:

* kant < 1 och korn > 1 — suddig på kanterna, grynig på ytorna. Det värsta fallet,
  och det enda skärpetalet inte kan se.
* kant ≈ 1 och korn ≈ 1 — så nära fotot man kommer.
* kant < 1 och korn < 1 — genomgående dis.

    python tools/kant_check.py <skanningsmapp> <modell.ply|.spz> [...]
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
PATCHES = 12   # så många kantrika rutor per foto


def _grey(image: np.ndarray) -> np.ndarray:
    return np.asarray(image, dtype=np.float32).mean(axis=2)


def _edges(image: np.ndarray) -> np.ndarray:
    """Kantstyrka per pixel. Samma mått som ``splat_check`` och telefonen."""
    return (np.abs(np.diff(image, axis=0)[:, :-1])
            + np.abs(np.diff(image, axis=1)[:-1, :]))


def _edgy_boxes(photo: np.ndarray) -> list[tuple[int, int]]:
    """De kantrikaste rutorna i fotot, utan överlapp.

    Spegelbilden av ``korn2._smooth_boxes``: där valdes de jämnaste för att
    kornet skulle synas, här de skarpaste för att suddet ska göra det.
    """
    strength_map = _edges(photo)
    height, width = strength_map.shape
    rows, columns = height // BOX, width // BOX
    tiles = strength_map[:rows * BOX, :columns * BOX].reshape(rows, BOX, columns, BOX)
    strength = tiles.mean(axis=(1, 3))
    order = np.argsort(strength, axis=None)[::-1][:PATCHES]
    return [(int(index // columns) * BOX, int(index % columns) * BOX) for index in order]


def _read(path: Path):
    return read_spz(path) if path.suffix == ".spz" else read_ply(path)


def _calibrate(bundle, chosen) -> int:
    """Vad kvoten betyder i PIXLAR, mätt genom att sudda fotot mot sig självt.

    Kvoten är enhetslös och därför omöjlig att bedöma: 0,62 kan vara en hårsmån
    eller ett utsmetat rum. Här suddas fotot med kända bredder och mäts med
    exakt samma rutor och samma kvot, så talet kan läsas av mot en linjal i
    stället för mot magkänsla.
    """
    from scipy.ndimage import gaussian_filter

    print(f"{'suddets sigma':<16} {'kvot':>8}")
    for sigma in (0.25, 0.5, 0.75, 1.0, 1.5, 2.0, 3.0):
        ratios = []
        for index in chosen:
            photo = _grey(np.asarray(bundle.keyframes[index].image))
            blurred_edges = _edges(gaussian_filter(photo, sigma))
            photo_edges = _edges(photo)
            for top, left in _edgy_boxes(photo):
                here = (slice(top, top + BOX), slice(left, left + BOX))
                ratios.append(float(blurred_edges[here].mean())
                              / max(float(photo_edges[here].mean()), 1e-6))
        print(f"{sigma:<16.2f} {np.median(ratios):>7.2f}x")
    return 0


def main(argv: list[str]) -> int:
    # Med ``--training-views`` mäts i stället de foton modellen TRÄNATS på. Det
    # är normalt fusk, men som kontroll är det just vad man vill ha: kan
    # modellen inte återge ens de bilder den anpassats mot sitter taket i data
    # eller i kapaciteten, inte i generaliseringen.
    training = "--training-views" in argv
    argv = [argument for argument in argv if argument != "--training-views"]

    room = Path(argv[1])
    bundle = ScanBundle.load(room)
    every_tenth = set(range(0, len(bundle.keyframes), 10))
    chosen = ([index for index in range(len(bundle.keyframes))
               if index not in every_tenth] if training else sorted(every_tenth))

    if "--calibrate" in argv:
        return _calibrate(bundle, chosen)

    print(f"{'modell':<24} {'kantskärpa mot fotots':>24}"
          f"  ({'tränade' if training else 'undanhållna'} vyer)")
    for argument in argv[2:]:
        path = Path(argument)
        views = synthetic_keyframes(_read(path), bundle, extra_views=0)
        ratios = []
        for index in chosen:
            rendered = _grey(views[index].image)
            photo = np.asarray(bundle.keyframes[index].image)
            if photo.shape[:2] != rendered.shape:
                from PIL import Image
                photo = np.asarray(Image.fromarray(photo).resize(
                    (rendered.shape[1], rendered.shape[0])))
            photo = _grey(photo)

            rendered_edges, photo_edges = _edges(rendered), _edges(photo)
            for top, left in _edgy_boxes(photo):
                here = (slice(top, top + BOX), slice(left, left + BOX))
                ratios.append(float(rendered_edges[here].mean())
                              / max(float(photo_edges[here].mean()), 1e-6))
        print(f"{path.name:<24} {np.median(ratios):>23.2f}x")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
