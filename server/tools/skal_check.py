"""Mäter frostskalet: hur långt från den mätta ytan massan faktiskt ligger.

Det här är det fel ingen av de andra mätarna kan se. ``splat_check`` delar
kantstyrka, ``kant_check`` gör det där fotot har kanter och ``korn2`` mäter
skiftet där fotot är jämnt — men alla tre tittar på BILDEN. Vit frost på en vit
vägg kostar ingenting i bild: felkartan visar bara kanter och väggarna ser
felfria ut. Ändå är det frosten som gör att rummet inte går att gå in i, för så
fort kameran flyttar sig avslöjar parallaxen att färgen satt en centimeter för
nära.

Måttet frågar i stället GEOMETRIN: hur nära den mätta ytan ligger varje gaussare,
och hur stor del av den synliga massan som sitter på ytan i stället för framför
den. Uppmätt på 3DGS låg bara 1,4 % av massan närmare än 2 mm medan 78 % svävade
5–20 mm ut — och dimmåttet i ``splat_check`` börjar först vid 3 cm, så det missar
hela skalet.

Ytan är ``measured_points``, inte meshen: meshen tappar gardiner, växter och
soffkanter, och en gaussare som sitter rätt på en gardin skulle annars räknas som
svävande.

Massan vägs med opacitet gånger skivans area — det är den synliga massan, inte
antalet. En miljon nästan genomskinliga gaussare långt ut betyder mindre än
tiotusen täckande, och det är just den skillnaden som avgör hur rummet SER ut.

    python tools/skal_check.py <skanningsmapp> <modell.ply|.spz> [...]

Läs talet så här: andelen inom 2 mm ska UPP. Går den upp medan ``kant_check``
står stilla har geometrin blivit bättre utan att bilden blivit sämre, och det är
hela poängen med ytelement.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle, measured_points  # noqa: E402
from splat_check import read_ply, read_spz  # noqa: E402

#: Gränserna mätningen delas upp i, i meter. Den första är "på ytan": tunnare än
#: så kan LiDAR-mätningen själv inte skilja.
BANDS = (0.002, 0.005, 0.020, 0.050)

#: Hur fint ytmolnet fälls ut. MÅSTE vara mycket finare än det man vill mäta.
#:
#: Det här talet lurade oss en gång och får inte göra det igen. Med ``bundle``-
#: förvalet 1 cm ligger molnets EGNA punkter 7,9 mm från sin närmaste granne —
#: halva rymddiagonalen i en centimeterkub är 8,7 mm. En gaussare som sitter
#: perfekt på ytan mättes alltså som svävande, och "78 % av massan svävar
#: 5–20 mm" var till största delen rutnätet, inte modellen. Vid 2 mm är golvet
#: 4,8 mm och kvar blir bara det som faktiskt svävar.
VOXEL = 0.002


def _mass(model) -> np.ndarray:
    """Synlig massa per gaussare: opacitet gånger skivans area.

    Arean tas ur de TVÅ största skalorna. Den minsta är tjockleken, och en skiva
    syns inte mer för att den är tjock — det är utbredningen längs ytan som
    täcker pixlar.
    """
    scales = np.sort(np.exp(model.scales), axis=1)
    alpha = 1.0 / (1.0 + np.exp(-model.opacities.reshape(-1)))
    return alpha * scales[:, 1] * scales[:, 2]


def main(argv: list[str] | None = None) -> int:
    arguments = (argv if argv is not None else sys.argv[1:])
    if len(arguments) < 2:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2

    from scipy.spatial import cKDTree

    bundle = ScanBundle.load(Path(arguments[0]))
    surface = measured_points(bundle.keyframes, voxel=VOXEL)
    tree = cKDTree(surface)

    # Golvet mäts varje gång och skrivs ut FÖRE modellerna. Ett avstånd som inte
    # står bredvid sitt golv går inte att tolka: molnet är självt utspritt, så
    # även en perfekt yta hamnar en bit ut.
    spacing, _ = tree.query(surface, k=2, workers=-1)
    floor = float(np.median(spacing[:, 1]))
    print(f"ytan: {len(surface)} mätta punkter, {1000 * VOXEL:.0f} mm rutnät")
    print(f"GOLV: molnets egen granndistans median {1000 * floor:.1f} mm — "
          f"en gaussare PÅ ytan mäter så här långt ut. Räkna bort det.")

    for name in arguments[1:]:
        path = Path(name)
        model = read_spz(path) if path.suffix == ".spz" else read_ply(path)
        distance, _ = tree.query(model.means, k=1, workers=-1)
        mass = _mass(model)
        total = mass.sum()

        parts = []
        previous = 0.0
        for edge in BANDS:
            inside = (distance >= previous) & (distance < edge)
            parts.append(f"{previous * 1000:.0f}–{edge * 1000:.0f} mm "
                         f"{100 * mass[inside].sum() / total:.1f} %")
            previous = edge
        parts.append(f">{BANDS[-1] * 1000:.0f} mm "
                     f"{100 * mass[distance >= BANDS[-1]].sum() / total:.1f} %")

        weighted = _weighted_median(distance, mass)
        print(f"\n{path.name}: {len(model.means)} gaussare")
        print("  massa per avstånd till ytan: " + ", ".join(parts))
        print(f"  median {1000 * np.median(distance):.1f} mm, "
              f"massvägd median {1000 * weighted:.1f} mm")
        # Det här är talet som betyder något: allt utöver golvet.
        print(f"  ÖVERSKOTT över golvet: {1000 * (weighted - floor):.1f} mm")

    return 0


def _weighted_median(values: np.ndarray, weights: np.ndarray) -> float:
    """Medianen räknad på massan i stället för på antalet.

    Skillnaden mot den vanliga medianen är själva poängen: ligger de två långt
    isär bärs bilden av få stora gaussare, och då säger antalet inget om vad man
    ser.
    """
    order = np.argsort(values)
    sorted_weights = weights[order]
    crossing = np.searchsorted(np.cumsum(sorted_weights), 0.5 * weights.sum())
    return float(values[order][min(crossing, len(values) - 1)])


if __name__ == "__main__":
    raise SystemExit(main())
