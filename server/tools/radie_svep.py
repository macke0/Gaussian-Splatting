"""Sveper ``MAXIMUM_RADIUS`` och mäter sudd och korn för varje värde.

Sex millimeter valdes mot det GLOBALA skärpetalet, och det talet kan bevisligen
inte skilja sudd från korn — det stiger av båda. Konstanten styr dessutom exakt
den avvägning måttet är blint för, så den är vald mot fel våg.

Räkna om taket till pixlar och det syns varför det gör ont: 6 mm på 2,5 meters
håll med f = 1086 blir 2,6 pixlar. Varje gaussare i rummet är alltså en tre
pixlar bred bricka med sin egen färg. En slät vägg blir en mosaik av tusentals
oberoende brickor — det är kornet — och en kant kan inte bli skarpare än den
bricka som ritar den — det är suddet. Ett enda tal förklarar båda mätvärdena.

Andra splattar har inget sådant tak. Där växer gaussarna sig stora och släta på
en tom vägg och delas bara där gradienten säger att det behövs, alltså vid
kanterna. Formen följer bilden i stället för en konstant.

Tjockleks- och ytspärren står kvar under hela svepet. Det är de som håller
gaussarna på ytan, och en bred skiva som ligger PÅ väggen är inte dis.

    python tools/radie_svep.py <skanningsmapp> <utmapp> [radie i mm ...]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server import splat as splat_module  # noqa: E402
from spatialfit_server.bundle import ScanBundle  # noqa: E402

#: Millimeter. Nuvarande värdet först som kontroll att svepet mäter samma sak
#: som baslinjen, sedan uppåt tills gaussarna får vara så stora de vill.
RADII = (6, 20, 60, 1000)


def main(argv: list[str] | None = None) -> int:
    import logging

    arguments = (argv if argv is not None else sys.argv[1:])
    if len(arguments) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    bundle = ScanBundle.load(Path(arguments[0]))
    target = Path(arguments[1])
    target.mkdir(parents=True, exist_ok=True)
    radii = [int(value) for value in arguments[2:]] or list(RADII)

    for millimetres in radii:
        splat_module.MAXIMUM_RADIUS = millimetres / 1000.0
        print(f"\n=== radie {millimetres} mm ===", flush=True)
        model = splat_module.train(bundle)
        splat_module.write_ply(model, target / f"radie{millimetres}.ply")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
