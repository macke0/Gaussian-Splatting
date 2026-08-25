"""Tränar en gaussian splat på en skanning och skriver den som PLY.

Skild från bakningen med flit. `bake_room --color-source splat` tränar också, men
bakar sedan ned resultatet i en diffus atlas — och det är den nedbakningen som
tar bort det som gör en splat snygg. Det här verktyget lämnar splatten som den
är, så den går att öppna i en vanlig visare och bedömas för vad den är.

    .venv/bin/python tools/train_splat.py <skanningsmapp> --output rum.ply

Kräver CUDA.
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import (DEFAULT_ITERATIONS, DEFAULT_MAX_SPLATS,  # noqa: E402
                                     POSE_LEARNING_RATE, synthetic_keyframes,
                                     train, write_ply, write_spz)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Träna en splat på ett skannat rum.")
    parser.add_argument("directory", type=Path,
                        help="mappen med room.mesh, keyframes.json och fotona")
    parser.add_argument("--output", type=Path, default=None,
                        help="var filen ska hamna; .spz ger SPZ, annars PLY "
                             "(förval: room.ply i rummets mapp)")
    parser.add_argument("--iterations", type=int, default=DEFAULT_ITERATIONS)
    parser.add_argument("--max-splats", type=int, default=DEFAULT_MAX_SPLATS)
    parser.add_argument("--no-densify", action="store_true",
                        help="behåll en gaussare per LiDAR-hörn")
    parser.add_argument("--no-refine-poses", action="store_true",
                        help="lås kamerorna vid ARKits poser")
    parser.add_argument("--pose-lr", type=float, default=POSE_LEARNING_RATE,
                        help="kamerornas inlärningstakt; sätter hur långt de KAN "
                             "gå. Felet som ska rättas är 2–3 cm, så följ "
                             "flyttlogen: rör de sig mycket mindre än så är "
                             "kopplet för hårt och rummet blir suddigt")
    parser.add_argument("--holdout", type=int, default=0, metavar="N",
                        help="träna INTE på vart N:te foto. Satt till 10 blir de "
                             "undanhållna exakt de `splat_check` mäter mot, så "
                             "talen gäller vyer modellen aldrig sett. Behövs när "
                             "det som ändras är poserna: mätt i egna träningsvyer "
                             "ser en lös kamera alltid bra ut")
    parser.add_argument("--gradient-densification", action="store_true",
                        help="förtäta där SKÄRMGRADIENTEN är stor (gsplats "
                             "DefaultStrategy) i stället för att flytta slocknade "
                             "gaussare mot ett fast tak (MCMC). Slår samtidigt av "
                             "MINIMUM_ALPHA och MCMC-straffen, som annars sätter "
                             "opacitetsnollställningen ur spel. Antalet gaussare "
                             "blir inte längre exakt PHONE_SPLAT_BUDGET")
    parser.add_argument("--preview", type=int, default=None, metavar="FOTO",
                        help="skriv splatten och fotot sida vid sida bredvid PLY:n")
    arguments = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(message)s")

    try:
        bundle = ScanBundle.load(arguments.directory)
        if arguments.holdout:
            kept = [frame for index, frame in enumerate(bundle.keyframes)
                    if index % arguments.holdout]
            print(f"tränar på {len(kept)} av {len(bundle.keyframes)} foton")
            bundle = dataclasses.replace(bundle, keyframes=kept)
        model = train(bundle,
                      iterations=arguments.iterations,
                      max_splats=arguments.max_splats,
                      densify=not arguments.no_densify,
                      refine_poses=not arguments.no_refine_poses,
                      pose_learning_rate=arguments.pose_lr,
                      gradient_densification=arguments.gradient_densification)
    except (FileNotFoundError, ValueError, RuntimeError) as error:
        print(f"Gick inte att träna: {error}", file=sys.stderr)
        return 1

    # Ändelsen väljer format. PLY är förval här och inte i bakningen med flit:
    # verktyget finns för att kunna öppna splatten i vilken visare som helst,
    # och alla läser PLY medan färre läser SPZ.
    destination = arguments.output or arguments.directory / "room.ply"
    (write_spz if destination.suffix == ".spz" else write_ply)(model, destination)

    if arguments.preview is not None:
        _preview(model, bundle, arguments.preview, destination.with_suffix(".png"))
    return 0


def _preview(model, bundle: ScanBundle, index: int, path: Path) -> None:
    """Splatten till vänster, fotot den tränades på till höger.

    Utan den här bilden går det bara att säga att förlusten sjönk, och en sjunken
    förlust har vi sett vara förenlig med ett suddigt rum.
    """
    from PIL import Image

    # Fick kamerorna glida under träningen är det de justerade poserna splatten
    # är skarp i. Renderar vi från ARKits ursprungliga jämför vi mot en vy
    # modellen aldrig såg, och drar fel slutsats om skärpan.
    if model.poses is not None:
        bundle = dataclasses.replace(bundle, keyframes=[
            dataclasses.replace(frame, camera_from_world=pose)
            for frame, pose in zip(bundle.keyframes, model.poses)])

    rendered = synthetic_keyframes(model, bundle, extra_views=0)[index]
    photo = bundle.keyframes[index].image
    height, width = rendered.image.shape[:2]

    side = Image.new("RGB", (width * 2, height))
    side.paste(Image.fromarray(rendered.image), (0, 0))
    side.paste(Image.fromarray(photo).resize((width, height)), (width, 0))
    side.save(path)
    print(f"skrev {path}")


if __name__ == "__main__":
    raise SystemExit(main())
