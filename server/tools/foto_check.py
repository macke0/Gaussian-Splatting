"""Mäter hur skarpa SKANNINGENS EGNA FOTON är, innan något tränas.

Varje mått vi har jämför renderingen med ett foto och antar därmed tyst att
fotot är skarpt. Det är inte självklart. ARKits keyframes är videobildrutor
tagna medan kunden GÅR genom rummet, inte stillbilder: rullande slutare,
rörelseoskärpa och en automatik som jagar exponering. Är hälften av dem suddiga
kan ingen modell bli skarpare än snittet, för träningen ser alla foton som lika
sanna. Då sitter felet i insamlingen och inte en enda konstant i träningen kan
laga det.

Måttet är Crete-Roffets referensfria oskärpemått. Bilden suddas med en känd
kärna och man mäter hur mycket grannskillnaderna FÖRÄNDRAS: en redan suddig bild
ändras nästan inte, en skarp bild ändras mycket. Talet ligger i [0, 1] där högre
är suddigare.

Det ersätter ett tidigare mått som summerade ``mean|gradient|`` och som var
odugligt: för en monoton kant BEVARAS den summan under suddning — gradienten
blir lägre men bredare och arean densamma. Det gamla talet mätte alltså mängden
HÖGFREKVENT BRUS, och friskrev en gång fotona från rörelseoskärpa på den grunden.
Crete-Roffet är dessutom kontrastoberoende, och det är hela poängen: talen ska gå
att jämföra mellan vår skanning och ett främmande referensdataset som
fotograferats med annan kamera, annan optik och annan exponering.

    python tools/foto_check.py <skanningsmapp eller mapp med bilder> [--bredd N]

``--bredd`` skalar varje bild till N pixlars bredd före mätningen och är
NÖDVÄNDIG när två dataset jämförs. Kärnan är fast på nio pixlar, så samma motiv
i högre upplösning får ett lägre tal utan att vara skarpare. Utan flaggan mäter
man upplösningsskillnaden och tror att man mätt oskärpa.

Talet är kalibrerat mot känd gaussisk suddning av ett av våra egna foton, så
skillnader går att läsa som pixlar i stället för som en enhetslös kvot:

    ===== =======
    sigma oskärpa
    ===== =======
    0     0,313
    0,5   0,351
    1     0,453
    2     0,670
    3     0,808
    5     0,927
    ===== =======

Ett foto som ligger på 0,45 är alltså ungefär en pixel suddigare än ett på 0,31.
Gör om tabellen om ``bundle.BLUR_SPAN`` ändras.

Läs talet så här: ligger fotona tätt är de lika bra och urval hjälper inte. Är
spridningen stor finns det skarpa foton att välja, och de suddiga drar ned alla
andra — precis som varje seriös fotogrammetripipeline sorterar bort dem. Och är
MEDIANEN mycket högre än referensdatasetets är det filmningen som binder, hur
mycket vi än skruvar på träningen.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

# Måttet bor i paketet, för träningen viktar fotona med det numera. Två kopior
# av den här matematiken är två chanser att bara den ena rättas.
from spatialfit_server.bundle import blur as _blur  # noqa: E402

#: Så många bilder mäts, jämnt spridda över mappen. Fördelningen behöver inte
#: fler, och referensdataseten har tusentals bilder i full upplösning.
SAMPLES = 60


def _images(where: Path) -> list[Path]:
    """Både våra skanningar och ett främmande dataset ska gå att peka på."""
    if (where / "keyframes.json").exists():
        return sorted(where.glob("kf*.jpg"), key=lambda path: int(path.stem[2:]))
    return sorted(path for path in where.rglob("*")
                  if path.suffix.lower() in {".jpg", ".jpeg", ".png"})


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]
    if not arguments:
        print("python tools/foto_check.py <mapp>", file=sys.stderr)
        return 2

    where = Path(arguments[0])
    width = int(arguments[arguments.index("--bredd") + 1]) \
        if "--bredd" in arguments else 0

    paths = _images(where)
    if not paths:
        print(f"inga bilder i {where}", file=sys.stderr)
        return 1

    sample = paths[::max(1, len(paths) // SAMPLES)]
    values, measured = [], None
    for path in sample:
        picture = Image.open(path).convert("L")
        if width:
            picture = picture.resize(
                (width, round(picture.height * width / picture.width)),
                Image.LANCZOS)
        measured = picture.size
        values.append(_blur(np.asarray(picture, dtype=np.float64) / 255.0))
    values = np.array(values)
    order = np.argsort(values)

    print(f"{where}")
    # Den MÄTTA storleken, inte filens: skalas bilderna om är det den som gäller,
    # och en jämförelse mellan två dataset står och faller med att den är lika.
    print(f"  {len(sample)} av {len(paths)} bilder, mätta vid {measured}"
          f" (filen {Image.open(sample[0]).size})")
    for label, value in (("skarpaste", values[order[0]]),
                         ("p10", np.percentile(values, 10)),
                         ("median", np.median(values)),
                         ("p90", np.percentile(values, 90)),
                         ("suddigaste", values[order[-1]])):
        print(f"  {label:<11} {value:.3f}")
    print(f"  suddigaste tolv: "
          f"{sorted(sample[index].name for index in order[-12:])}")
    print("  (0 = knivskarpt, 1 = helt sudd; jämför dataset med MEDIANEN)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
