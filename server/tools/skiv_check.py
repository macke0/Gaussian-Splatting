"""Ligger gaussarna LÄNGS ytan, eller är de kulisser vända mot kameran?

Det här avgör en anklagelse: att träningen skulle ha fuskat och byggt platta
teaterkulisser i stället för att beskriva rummet — "billboards". Symptomet
stämmer (knivskarpt från ett håll, sönderfall däremellan), men symptomet stämmer
lika bra med att vyn helt enkelt hamnat där ingen kamera stod. Anklagelsen måste
alltså prövas, inte antas.

Den går att pröva, för vi har något de flesta 3DGS-projekt saknar: en UPPMÄTT
yta. LiDAR-meshen vet var väggen är och åt vilket håll den vetter, oberoende av
varje foto. Då blir de två förklaringarna två SKILDA förutsägelser om samma tal:

    ärlig yta   gaussarens tunna axel pekar längs YTANS normal
    kuliss      gaussarens tunna axel pekar mot KAMERAN

De sammanfaller när man ser en vägg rakt framifrån, så bara gaussare som ses
SNETT säger något. Därför vägs allt mot vinkeln mellan ytnormalen och kameran:
är den liten bär punkten ingen information och tas inte med.

    .venv/bin/python tools/skiv_check.py <skanningsmapp> <modell.ply>
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from scipy.spatial import cKDTree

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from splat_check import read_ply  # noqa: E402

#: Så många gaussare prövas. Fler ändrar inte medianerna, bara väntetiden.
SAMPLES = 200_000

#: Hur nära meshen en gaussare måste ligga för att ytans normal ska gälla för
#: den. Längre bort är det en flygare, och en flygare har ingen yta att vara
#: trogen mot — den ska inte få rösta om kulissfrågan.
NEAR = 0.05

#: Hur platt en gaussare måste vara för att över huvud taget ha en riktning. En
#: nästan rund gaussare har ingen tunn axel att tala om; dess "normal" är brus.
FLAT = 0.5

#: Hur snett ytan måste ses för att de två förklaringarna ska skilja sig åt.
#: Under det här är kameran nästan rakt emot väggen, och då pekar både ytnormal
#: och kamerariktning åt samma håll — punkten kan inte avgöra något.
OBLIQUE = 30.0


def _normals(quats: np.ndarray, scales: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Varje gaussares tunna axel, och hur platt den är.

    Kvaternionens rotationsmatris har gaussarens tre huvudaxlar som kolumner.
    Den tunna axeln är kolumnen som hör till den minsta skalan; plattheten är
    minsta skalan delad med den mellersta.
    """
    quats = quats / np.linalg.norm(quats, axis=1, keepdims=True)
    w, x, y, z = quats.T
    matrix = np.stack([
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    ], axis=1).reshape(-1, 3, 3)

    sizes = np.exp(scales)
    thinnest = np.argmin(sizes, axis=1)
    normal = np.take_along_axis(
        matrix, thinnest[:, None, None].repeat(3, axis=1), axis=2)[:, :, 0]

    ordered = np.sort(sizes, axis=1)
    return normal, ordered[:, 0] / np.maximum(ordered[:, 1], 1e-12)


def _cameras(keyframes) -> np.ndarray:
    """Var varje foto togs. Kolumn fyra av det inverterade läget."""
    return np.array([
        -frame.camera_from_world[:3, :3].T @ frame.camera_from_world[:3, 3]
        for frame in keyframes])


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]
    if len(arguments) < 2:
        print("python tools/skiv_check.py <skanningsmapp> <modell.ply>", file=sys.stderr)
        return 2

    bundle = ScanBundle.load(Path(arguments[0]))
    model = read_ply(Path(arguments[1]))
    mesh = bundle.mesh

    generator = np.random.default_rng(0)
    chosen = generator.choice(len(model.means),
                              min(SAMPLES, len(model.means)), replace=False)
    means = model.means[chosen].astype(np.float64)
    normal, flatness = _normals(model.quats[chosen].astype(np.float64),
                                model.scales[chosen].astype(np.float64))

    # Närmaste triangel via dess tyngdpunkt. Trianglarna är små mot NEAR, så
    # skillnaden mot ett riktigt närmaste-punkt-anrop är försumbar — och det här
    # tar sekunder i stället för minuter.
    corners = mesh.positions[mesh.indices.astype(np.int64)]
    centroids = corners.mean(axis=1)
    distance, face = cKDTree(centroids).query(means)

    facing = np.cross(corners[:, 1] - corners[:, 0], corners[:, 2] - corners[:, 0])
    facing /= np.maximum(np.linalg.norm(facing, axis=1, keepdims=True), 1e-12)

    cameras = _cameras(bundle.keyframes)
    _, nearest = cKDTree(cameras).query(means)
    toward = cameras[nearest] - means
    toward /= np.maximum(np.linalg.norm(toward, axis=1, keepdims=True), 1e-12)

    surface = facing[face]
    # Bara riktningen räknas, inte tecknet: en gaussare är symmetrisk, och en
    # ytnormal kan vara vänd inåt eller utåt beroende på hur meshen veks.
    obliquity = np.degrees(np.arccos(np.clip(
        np.abs((surface * toward).sum(axis=1)), 0.0, 1.0)))

    usable = ((distance <= NEAR) & (flatness <= FLAT) & (obliquity >= OBLIQUE))
    print(f"{len(chosen)} gaussare, varav {usable.sum()} användbara "
          f"(inom {NEAR * 100:.0f} cm, plattare än {FLAT}, sedda snett)")
    if usable.sum() < 100:
        print("för få för att säga något", file=sys.stderr)
        return 1

    to_surface = np.degrees(np.arccos(np.clip(
        np.abs((normal[usable] * surface[usable]).sum(axis=1)), 0.0, 1.0)))
    to_camera = np.degrees(np.arccos(np.clip(
        np.abs((normal[usable] * toward[usable]).sum(axis=1)), 0.0, 1.0)))

    print(f"\nvinkeln mellan gaussarens tunna axel och ...")
    print(f"  {'':10} {'p25':>6} {'median':>7} {'p75':>6}")
    for label, value in (("ytans normal", to_surface), ("kameran", to_camera)):
        p25, median, p75 = np.percentile(value, (25, 50, 75))
        print(f"  {label:<10} {p25:6.1f}° {median:7.1f}° {p75:6.1f}°")

    # Det avgörande talet: hur ofta ligger axeln NÄRMARE kameran än ytan? Är
    # gaussarna ärliga ska det vara en klar minoritet.
    kulisser = (to_camera < to_surface).mean()
    print(f"\n  närmare kameran än ytan: {kulisser:6.1%}")
    print(f"  längs ytan (<30° från normalen): {(to_surface < 30).mean():6.1%}")
    print(f"  vänd mot kameran (<30° från den): {(to_camera < 30).mean():6.1%}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
