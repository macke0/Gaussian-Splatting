"""Mäter hur skarpa SKANNINGENS EGNA FOTON är, innan något tränas.

MÅTTET NEDAN ÄR TRASIGT — LITA INTE PÅ TALEN. `energy` summerar ``mean|∇I|``,
och för en monoton kant BEVARAS den summan under suddning: gradienten blir lägre
men bredare, och arean under den är densamma. Kvoten mäter alltså hur mycket
HÖGFREKVENT BRUS bilden har, inte hur suddig den är. Talen verktyget gav
(p90/p10 1,21×) friskrev därför INTE fotona från rörelseoskärpa, vilket är precis
den slutsats som drogs ur dem en gång. Gör om med varians av Laplacian eller med
uppmätt kantbredd innan rörelseoskärpa avfärdas igen. Ligger kvar därför att
frågan är riktig och insamlingen fortfarande är omätt.

Varje mått vi har jämför renderingen med ett foto och antar därmed tyst att
fotot är skarpt. Det är inte självklart. ARKits keyframes är videobildrutor
tagna medan kunden GÅR genom rummet, inte stillbilder: rullande slutare,
rörelseoskärpa och en automatik som jagar exponering. Är hälften av dem suddiga
kan ingen modell bli skarpare än snittet, för träningen ser alla foton som lika
sanna. Då sitter felet i insamlingen och inte en enda konstant i träningen kan
laga det.

Skärpan mäts innehållsokänsligt. Kantenergi ensam duger inte — en bild på en tom
vägg har lite kantenergi hur skarp den än är. I stället jämförs fotot med sig
självt suddat: ett skarpt foto TAPPAR mycket på att suddas, ett redan suddigt
tappar lite. Kvoten säger alltså hur mycket skärpa som finns att förlora.

    python tools/foto_check.py <skanningsmapp>

Läs talet så här: ligger fotona tätt är de lika bra och urval hjälper inte.
Är spridningen stor finns det skarpa foton att välja, och de suddiga drar ned
alla andra — precis som varje seriös fotogrammetripipeline sorterar bort dem.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402


def _sharpness(image: np.ndarray) -> float:
    """Kantenergi delat med samma bilds kantenergi efter en lätt suddning."""
    grey = np.asarray(image, np.float32).mean(axis=2)
    # Tre pixlars glidande medel i båda led. Litet med flit: det ska likna den
    # oskärpa en hand ger på en tjugondels sekund, inte sudda sönder bilden.
    padded = np.pad(grey, 1, mode="edge")
    blurred = sum(padded[row:row + grey.shape[0], column:column + grey.shape[1]]
                  for row in range(3) for column in range(3)) / 9.0

    def energy(picture: np.ndarray) -> float:
        return float(np.abs(np.diff(picture, axis=0)).mean()
                     + np.abs(np.diff(picture, axis=1)).mean())

    return energy(grey) / max(energy(blurred), 1e-6)


def main(argv: list[str] | None = None) -> int:
    arguments = (argv if argv is not None else sys.argv[1:])
    if not arguments:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2

    bundle = ScanBundle.load(Path(arguments[0]))
    scores = np.array([_sharpness(frame.image) for frame in bundle.keyframes])
    order = np.argsort(scores)

    print(f"{len(scores)} foton")
    for label, value in (("sämsta", scores[order[0]]),
                         ("p10", np.percentile(scores, 10)),
                         ("median", np.median(scores)),
                         ("p90", np.percentile(scores, 90)),
                         ("bästa", scores[order[-1]])):
        print(f"  {label:<7} {value:.3f}")
    print(f"  bästa/sämsta {scores[order[-1]] / scores[order[0]]:.2f}x, "
          f"p90/p10 {np.percentile(scores, 90) / np.percentile(scores, 10):.2f}x")

    # Vilka foton som är dåliga spelar roll: ligger de suddiga utspridda över
    # hela varvet kan de plockas bort utan att något hål uppstår.
    worst = [bundle.keyframes[index].id for index in order[:12]]
    print(f"  suddigaste tolv: {sorted(worst)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
