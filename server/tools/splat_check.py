"""Sätter siffror på en färdig splat, så två körningar går att jämföra.

Förlusten i träningsloggen duger inte till det: den gäller ETT slumpat foto per
steg och svänger mellan 0,077 och 0,133 mellan två utskrifter, alltså mer än
skillnaden mellan två modeller. Och den är mätt i poser modellen tränats i, där
en splat alltid ser bättre ut än den är.

Tre tal per modell:

* **L1** mot fotot, för var tionde foto. Grovt mått på om färgen stämmer.
* **skärpa**, renderingens kantstyrka delad med fotots. Ett betyder lika skarp
  som verkligheten, en halv betyder utsmetad. Det här är talet som svarar mot
  vad man ser, inte L1 — dimma sänker L1 men skärpan avslöjar den.
* **dimma**, andelen synlig massa som sitter mer än ``MAXIMUM_DRIFT`` från den
  mätta ytan. Massa i luften är per definition inte rummet.

Poserna kommer från ARKit, inte från träningens justerade — PLY-formatet bär
inte kamerorna. Det gör alla tal en aning pessimistiska, men lika mycket för
alla modeller, så jämförelsen håller.

    python tools/splat_check.py <skanningsmapp> <modell.ply> [<modell.ply> ...]
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle, connected_surface  # noqa: E402
from spatialfit_server.splat import (MAXIMUM_DRIFT, SH_DC, SplatModel,  # noqa: E402
                                     synthetic_keyframes)

HOLDOUT = 10


def read_ply(path: Path) -> SplatModel:
    """Läser tillbaka det ``write_ply`` skrev."""
    with path.open("rb") as file:
        names, count = [], 0
        while True:
            line = file.readline().decode("ascii").strip()
            if line == "end_header":
                break
            if line.startswith("element vertex"):
                count = int(line.split()[2])
            elif line.startswith("property float"):
                names.append(line.split()[2])
        table = np.frombuffer(file.read(count * len(names) * 4),
                              np.float32).reshape(count, len(names))

    column = {name: index for index, name in enumerate(names)}
    take = lambda *keys: table[:, [column[key] for key in keys]]  # noqa: E731
    return SplatModel(
        means=take("x", "y", "z"),
        quats=take("rot_0", "rot_1", "rot_2", "rot_3"),
        scales=take("scale_0", "scale_1", "scale_2"),
        opacities=table[:, column["opacity"]],
        colors=take("f_dc_0", "f_dc_1", "f_dc_2") * SH_DC + 0.5)


def edge_strength(image: np.ndarray) -> float:
    """Medelskillnaden mellan grannpixlar — samma mått som bakningen väger med."""
    grey = image.astype(np.float32).mean(axis=2)
    return float(np.abs(np.diff(grey, axis=0)).mean()
                 + np.abs(np.diff(grey, axis=1)).mean())


room = Path(sys.argv[1])
bundle = ScanBundle.load(room)
surface, _ = connected_surface(bundle.mesh)

# Bara var tionde vy. Renderingen av två miljoner gaussare mot trehundra foton
# tar minuter, och trettio vyer räcker gott för ett medelvärde.
held_out = list(range(0, len(bundle.keyframes), HOLDOUT))

print(f"{len(bundle.keyframes)} foton, mäter mot {len(held_out)} av dem\n")
print(f"{'modell':<24} {'gaussare':>9} {'L1':>7} {'skärpa':>7} {'dimma':>7}")

for argument in sys.argv[2:]:
    path = Path(argument)
    model = read_ply(path)

    views = synthetic_keyframes(model, bundle, extra_views=0)
    errors, sharpness = [], []
    for index in held_out:
        rendered = views[index].image
        photo = np.asarray(bundle.keyframes[index].image)
        if photo.shape != rendered.shape:
            from PIL import Image
            photo = np.asarray(Image.fromarray(photo).resize(
                (rendered.shape[1], rendered.shape[0])))
        errors.append(float(np.abs(rendered.astype(np.float32)
                                   - photo.astype(np.float32)).mean() / 255))
        sharpness.append(edge_strength(rendered) / max(edge_strength(photo), 1e-6))

    # Vägd med opaciteten: en genomskinlig gaussare i luften syns knappt och ska
    # inte räknas lika tungt som en tät.
    #
    # Marginalen är inte en avrundning utan hela skillnaden mellan ett tal och
    # brus: träningen klämmer de drivna till PRECIS ``MAXIMUM_DRIFT``, så utan
    # den räknas varje kringelbunden gaussare som dimma och måttet visar 6,8 %
    # för en modell som per konstruktion inte kan ha någon.
    from scipy.spatial import cKDTree
    distance, _ = cKDTree(surface).query(model.means, k=1, workers=-1)
    alpha = 1 / (1 + np.exp(-model.opacities))
    fog = float(alpha[distance > MAXIMUM_DRIFT * 1.5].sum() / alpha.sum())

    print(f"{path.name:<24} {len(model):>9} {np.mean(errors):>7.4f} "
          f"{np.mean(sharpness):>7.1%} {fog:>7.1%}")

    # Talen säger att något är fel men inte vad. Ett suddigt rum, ett rum med
    # fel färg och ett rum som står en decimeter fel ger alla samma sänkta
    # skärpa — och de kräver helt olika åtgärder.
    from PIL import Image
    index = held_out[len(held_out) // 2]
    rendered = views[index].image
    photo = np.asarray(Image.fromarray(np.asarray(bundle.keyframes[index].image))
                       .resize((rendered.shape[1], rendered.shape[0])))
    side = Image.new("RGB", (rendered.shape[1] * 2, rendered.shape[0]))
    side.paste(Image.fromarray(rendered), (0, 0))
    side.paste(Image.fromarray(photo), (rendered.shape[1], 0))
    side.save(path.with_suffix(".jamforelse.png"))
    print(f"    {rendered.shape[1]}x{rendered.shape[0]}, "
          f"skrev {path.with_suffix('.jamforelse.png').name}")
