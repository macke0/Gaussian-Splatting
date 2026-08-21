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

from spatialfit_server.bundle import (ScanBundle, connected_surface,  # noqa: E402
                                      measured_points)
from spatialfit_server.splat import (MAXIMUM_DRIFT, SH_DC,  # noqa: E402
                                     _SPZ_COLOR_SCALE, SplatModel,
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


def read_spz(path: Path) -> SplatModel:
    """Läser tillbaka det ``write_spz`` skrev — alltså det TELEFONEN fick.

    PLY:n mäts före kvantiseringen och finns inte ens kvar på disk efter en
    bakning. Skillnaden mellan de två filerna är oprövad, och allt som händer
    här — tjugo byte per gaussare i stället för sextioåtta — kan bara göra
    modellen sämre. Därför måste den mätas, inte antas.
    """
    import gzip
    import struct

    blob = gzip.decompress(path.read_bytes())
    magic, version, count, _, fractional, _, _ = struct.unpack_from("<IIIBBBB", blob)
    assert magic == 0x5053474E and version == 3, (magic, version)

    at = 16
    def eat(width: int) -> np.ndarray:
        nonlocal at
        chunk = np.frombuffer(blob, np.uint8, count * width, at)
        at += count * width
        return chunk.reshape(count, width)

    positions, alphas, colors, scales, rotations = (
        eat(9), eat(1), eat(3), eat(3), eat(4))

    # Tre byte per led, litet ändvänt, och teckenbiten sitter i bit 23 — så
    # talet måste tecken-utvidgas för hand innan det blir ett avstånd.
    raw = (positions.reshape(count * 3, 3).astype(np.int32)
           << np.array([0, 8, 16], np.int32)).sum(axis=1)
    means = ((raw ^ 0x800000) - 0x800000).reshape(count, 3) / (1 << fractional)

    word = (rotations.astype(np.uint32)
            << np.array([0, 8, 16, 24], np.uint32)).sum(axis=1)
    quats = np.zeros((count, 4))
    largest = (word >> np.uint32(30)) & np.uint32(3)
    # De tre kvarvarande talen ligger i stigande indexordning från de höga
    # bitarna, eftersom skrivaren skiftade in dem i just den ordningen.
    packs = [(word >> np.uint32(shift)) & np.uint32(0x3FF) for shift in (20, 10, 0)]
    rows = np.arange(count)
    for index in range(4):
        keep = largest != index
        # Vilken av de tre luckorna talet hamnade i beror på hur många av de
        # lägre indexen som också behölls, alltså på var det utelämnade sitter.
        slot = np.where(index < largest, index, index - 1)
        value = np.choose(slot.clip(0, 2), packs)
        magnitude = (value & np.uint32(0x1FF)) / 511 * np.sqrt(0.5)
        quats[keep, index] = np.where(value & np.uint32(0x200),
                                      -magnitude, magnitude)[keep]
    # Det utelämnade räknas fram ur normen och antas positivt, precis som
    # skrivaren vände kvaternionen för att det skulle gälla.
    quats[rows, largest] = np.sqrt(np.clip(
        1 - (quats * quats).sum(axis=1), 0, None))

    # Höger-ned-fram tillbaka till ARKits höger-upp-bak, och xyzw till wxyz.
    # Allt räknas i dubbel precision hit, för kvaternionens norm tål inte annat,
    # men renderaren vill ha enkel.
    flip = np.array([1.0, -1.0, -1.0])
    alpha = (alphas[:, 0] / 255).clip(1 / 255, 254 / 255)
    single = lambda values: np.ascontiguousarray(values, np.float32)  # noqa: E731
    return SplatModel(
        means=single(means * flip),
        quats=single(quats[:, [3, 0, 1, 2]] * [1.0, *flip]),
        scales=single(scales / 16 - 10),
        opacities=single(np.log(alpha / (1 - alpha))),
        colors=single((colors / 255 - 0.5) / _SPZ_COLOR_SCALE * SH_DC + 0.5))


def edge_strength(image: np.ndarray) -> float:
    """Medelskillnaden mellan grannpixlar — samma mått som bakningen väger med."""
    grey = image.astype(np.float32).mean(axis=2)
    return float(np.abs(np.diff(grey, axis=0)).mean()
                 + np.abs(np.diff(grey, axis=1)).mean())


def main() -> None:
    room = Path(sys.argv[1])
    bundle = ScanBundle.load(room)
    # Samma yta som träningen klämmer mot, alltså meshen plus djupkartorna. Mot
    # bara meshen skulle varje gaussare som lagligt sitter på en gardin räknas
    # som dimma, och måttet mäta något annat än det spärren gör.
    mesh_surface, _ = connected_surface(bundle.mesh)
    surface = np.concatenate(
        [mesh_surface, measured_points(bundle.keyframes)]).astype(np.float32)

    # Bara var tionde vy. Renderingen av två miljoner gaussare mot trehundra foton
    # tar minuter, och trettio vyer räcker gott för ett medelvärde.
    held_out = list(range(0, len(bundle.keyframes), HOLDOUT))

    print(f"{len(bundle.keyframes)} foton, mäter mot {len(held_out)} av dem\n")
    print(f"{'modell':<24} {'gaussare':>9} {'L1':>7} {'skärpa':>7} {'dimma':>7}")

    for argument in sys.argv[2:]:
        path = Path(argument)
        model = read_spz(path) if path.suffix == ".spz" else read_ply(path)

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


if __name__ == "__main__":
    main()
