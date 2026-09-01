"""Delar upp svepet i tiondelar: är mitten suddigare, eller bara sämre täckt?

Bakgrunden är en iakttagelse som visade sig peka åt fel håll. Modellen var
knivskarp vid start- och slutläget av filmningen men smetig däremellan, och den
närmast liggande förklaringen var rörelseoskärpa — fotografen hinner accelerera
när han väl kommit i gång. Det är fel, och felet går bara att se genom att mäta
BÅDA förklaringarna på samma foton:

* **Rörelseoskärpa** ⇒ fotona i mitten ÄR suddigare. Mäts med Crete-Roffet, samma
  mått som ``bundle.blur`` viktar fotona med.
* **Täckning** ⇒ fotona är lika bra, men ytan i mitten ses från färre håll.
  Mäts som antalet grannfoton inom en meter.

Det senare måttet har en fälla som gör hela skillnaden: ett foto som togs mitt i
en serie har alltid många grannar, för de närmaste bildrutorna ligger några
centimeter bort. Den täthet som betyder något är den som kommer från ett ANNAT
tillfälle — ett andra pass över samma plats, från andra vinklar och med annan
exponering. Därför räknas bara grannar som ligger långt bort i BILDNUMMER.

    python tools/svep_check.py <skanningsmapp>

Läs utskriften så här. Ligger oskärpekolumnen platt är rörelseoskärpa avfärdad,
hur trolig den än lät. Faller kolumnen med tidsavlägsna grannar mot noll i
mitten gick fotografen ett slutet varv och passerade varje plats utom mitten en
andra gång — och då är det täckningen som ska lagas, i INSAMLINGEN, inte en enda
konstant i träningen.
"""
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import blur  # noqa: E402

#: Alla foton skalas hit före oskärpemätningen. Kärnan i ``blur`` är fast på
#: nio pixlar, så olika upplösning ger olika tal för samma motiv.
WIDTH = 640

#: Så nära ska två foton ligga för att räknas som grannar. En meter är ungefär
#: hur långt man kan flytta sig och ändå se samma yta.
NEIGHBOUR_RANGE = 1.0

#: Antal facken utskriften delas i.
BINS = 10


def _poses(room: Path) -> tuple[np.ndarray, np.ndarray]:
    """Kamerornas läge och blickriktning i världen.

    ``keyframes.json`` bär ``cameraFromWorldColumns``, alltså matrisens KOLUMNER
    som var sin lista. Kameran i världen är då ``-R^T t``, inte matrisens sista
    kolumn — den pekar åt motsatt håll och ger ett spegelvänt rum.
    """
    frames = json.loads((room / "keyframes.json").read_text())
    if isinstance(frames, dict):
        frames = frames.get("keyframes") or frames.get("frames")

    camera_from_world = np.array(
        [np.array(frame["cameraFromWorldColumns"], dtype=float).reshape(4, 4).T
         for frame in frames])
    rotation = camera_from_world[:, :3, :3]
    translation = camera_from_world[:, :3, 3]
    return -np.einsum("nji,nj->ni", rotation, translation), -rotation[:, 2, :]


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]
    if not arguments:
        print("python tools/svep_check.py <skanningsmapp>", file=sys.stderr)
        return 2

    room = Path(arguments[0])
    paths = sorted(room.glob("kf*.jpg"), key=lambda path: int(path.stem[2:]))
    position, forward = _poses(room)
    count = min(len(paths), len(position))
    if not count:
        print(f"inga foton i {room}", file=sys.stderr)
        return 1
    position, forward = position[:count], forward[:count]

    sharpness = []
    for path in paths[:count]:
        image = Image.open(path).convert("L")
        height = max(1, round(WIDTH * image.height / image.width))
        image = image.resize((WIDTH, height), Image.BILINEAR)
        sharpness.append(blur(np.asarray(image, dtype=np.float32) / 255.0))
    sharpness = np.array(sharpness)

    step = np.r_[0.0, np.linalg.norm(np.diff(position, axis=0), axis=1)]
    turn = np.r_[0.0, np.degrees(np.arccos(np.clip(
        np.sum(forward[1:] * forward[:-1], axis=1), -1.0, 1.0)))]

    neighbours = cKDTree(position).query_ball_point(position, r=NEIGHBOUR_RANGE)
    # Bara grannar från ett annat tillfälle. Utan det här filtret ser en serie
    # bilder i rad likadan ut som ett återbesök.
    apart = count // BINS
    revisits = np.array([sum(1 for other in group if abs(other - index) > apart)
                         for index, group in enumerate(neighbours)])

    print(f"{count} foton, {step.sum():.1f} m gången väg, "
          f"{np.linalg.norm(position[0] - position[-1]):.2f} m mellan start och slut")
    print(f"oskärpa median {np.median(sharpness):.4f}")
    print()
    print("tiondel   oskärpa  steg cm  vrid gr  grannar  därav återbesök")
    for index in range(BINS):
        part = slice(index * count // BINS, (index + 1) * count // BINS)
        print(f"{index * 10:3d}-{index * 10 + 10:3d}%  "
              f"{sharpness[part].mean():7.4f}  "
              f"{step[part].mean() * 100:7.1f}  "
              f"{turn[part].mean():7.1f}  "
              f"{np.array([len(g) for g in neighbours])[part].mean():7.1f}  "
              f"{revisits[part].mean():15.1f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
