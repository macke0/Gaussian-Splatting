"""Mäter hur bra ARKits kameraplaceringar är, genom att räkna fram dem igen.

Varje splat som duger bygger på COLMAP: bilderna matchas mot varandra och
kamerorna löses ut ur själva bilderna, till bråkdelen av en pixel. Vi hoppar
över det steget och litar på telefonens VIO. Det är billigt och snabbt, men
ingen har mätt vad det kostar — och ett fel i posen kan inte lagas av något
senare steg. Två foton som säger att samma kant sitter på olika ställen tvingar
träningen att lägga en gaussare mellan dem. Det ser ut som sudd, för det ÄR
sudd, och varken hårdare klämning eller fler gaussare hjälper.

Måttet gör det COLMAP gör, på samma foton, och jämför. Eftersom en rekonstruktion
ur bara bilder saknar skala läggs den först ovanpå ARKits med Umeyama — rotation,
förflyttning och EN skalfaktor. Det som blir kvar efteråt är oenighet.

    python tools/pose_check.py <skanningsmapp> [arbetsmapp]

Läs talet så här: står medianen i millimeter är VIO:n oskyldig och suddet sitter
någon annanstans. Står den i centimeter är det här felet, och då är det poserna
som ska lagas — inte träningen.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402


def _umeyama(source: np.ndarray, target: np.ndarray):
    """Likformig passning source → target: rotation, skala, förflyttning.

    Skalan måste vara med. COLMAP vet inte hur stort rummet är — bara hur det
    ser ut — så en rekonstruktion som är perfekt men halva storleken skulle
    annars mäta som helt fel.
    """
    source_mean, target_mean = source.mean(0), target.mean(0)
    a, b = source - source_mean, target - target_mean
    u, singular, vt = np.linalg.svd(a.T @ b / len(a))
    correction = np.eye(3)
    # Speglingen måste stängas ute: en spegelvänd lösning kan passa punkterna
    # lika bra i minsta kvadrat men är inte en stelkroppsrörelse.
    correction[2, 2] = np.sign(np.linalg.det(u @ vt))
    rotation = (u @ correction @ vt).T
    scale = float(singular @ np.diag(correction) / a.var(0).sum())
    return rotation, scale, target_mean - scale * rotation @ source_mean


def main(argv: list[str] | None = None) -> int:
    arguments = (argv if argv is not None else sys.argv[1:])
    if not arguments:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2

    import pycolmap

    scan = Path(arguments[0])
    work = Path(arguments[1] if len(arguments) > 1 else "/tmp/pose_check")
    work.mkdir(parents=True, exist_ok=True)
    database = work / "colmap.db"

    bundle = ScanBundle.load(scan)
    arkit = {f"kf{frame.id}.jpg": frame.position for frame in bundle.keyframes}
    first = bundle.keyframes[0]
    # COLMAPs bildpunkter räknas i jpg:ns pixlar och ``intrinsics`` i den
    # storlek telefonen skrev ned. Går de isär jämför vi två olika rutnät.
    print(f"{len(arkit)} keyframes, jpg {first.image.shape[1]}×{first.image.shape[0]}, "
          f"intrinsics för {first.image_size[0]:.0f}×{first.image_size[1]:.0f}")

    if not database.exists():
        # Ett enda kameraobjekt för alla foton. Det är samma lins hela vägen,
        # och delad kalibrering är både snabbare och stabilare än 297 gissningar.
        pycolmap.extract_features(database, scan, image_names=sorted(arkit),
                                  camera_mode=pycolmap.CameraMode.SINGLE)
        # Sekventiell matchning: fotona är tagna längs en väg, så grannar i tid
        # är grannar i rummet. Loop-stängningen är det som håller ihop varvet.
        pycolmap.match_sequential(database)
    print("matchning klar")

    # Rekonstruktionen tar ett par minuter, så en färdig läses hellre in igen.
    done = [path for path in sorted(work.iterdir())
            if path.is_dir() and (path / "cameras.bin").exists()]
    reconstructions = ({index: pycolmap.Reconstruction(str(path))
                        for index, path in enumerate(done)} if done else
                       pycolmap.incremental_mapping(database, scan, work))
    if not reconstructions:
        print("COLMAP registrerade INGA bilder — rummet är för slätt för SfM")
        return 1

    # Största delen räknas. Ett rum kan spricka i flera om en vägg är kal.
    best = max(reconstructions.values(), key=lambda r: r.num_reg_images())
    solved, measured = [], []
    for image in best.images.values():
        if image.name in arkit:
            solved.append(image.projection_center())
            measured.append(arkit[image.name])
    solved, measured = np.asarray(solved), np.asarray(measured)

    rotation, scale, offset = _umeyama(solved, measured)
    residual = np.linalg.norm(measured - (scale * solved @ rotation.T + offset), axis=1)

    print(f"{len(reconstructions)} delar, {len(solved)} av {len(arkit)} lösta, "
          f"{best.num_points3D()} punkter")
    colmap_error = best.compute_mean_reprojection_error()
    print(f"reprojektionsfel {colmap_error:.2f} px")
    print(f"skala {scale:.4f} (1,0 = COLMAP håller med om rummets storlek)")
    print(f"OENIGHET median {1000 * np.median(residual):.1f} mm, "
          f"p90 {1000 * np.percentile(residual, 90):.1f} mm, "
          f"värst {1000 * residual.max():.1f} mm")

    # Oenighet ensam pekar inte ut vem som har fel. Det gör det här: COLMAPs
    # punkter flyttas in i ARKits värld och kastas tillbaka på fotot genom
    # ARKits egen pose. Träffar de sin bildpunkt är VIO:n oskyldig. Missar de
    # med pixlar är det precis den oskärpan träningen tvingas måla.
    frames = {f"kf{frame.id}.jpg": frame for frame in bundle.keyframes}
    cloud = {number: point.xyz for number, point in best.points3D.items()}
    misses = []
    for image in best.images.values():
        frame = frames.get(image.name)
        if frame is None:
            continue
        seen = [(point.xy, cloud[point.point3D_id])
                for point in image.points2D if point.has_point3D()]
        if not seen:
            continue
        observed = np.asarray([xy for xy, _ in seen], np.float32)
        world = np.asarray([xyz for _, xyz in seen], np.float32)
        pixels, _ = frame.project(scale * world @ rotation.T + offset)
        misses.append(np.linalg.norm(pixels - observed, axis=1))
    miss = np.concatenate(misses)

    print(f"ARKits eget reprojektionsfel: median {np.median(miss):.1f} px, "
          f"p90 {np.percentile(miss, 90):.1f} px, {len(miss)} observationer")
    print(f"COLMAP på samma punkter: {colmap_error:.2f} px.")

    # Talet ovan blandar TVÅ fel som beter sig helt olika, och skillnaden är
    # avgörande. Ett posfel är slumpmässigt per foto: två bilder pekar ut samma
    # kant på olika ställen och träningen tvingas smeta ut den. Ett fel i
    # fokallängden är gemensamt för alla foton — bilden blir en aning för stor
    # eller för liten, men ALLA är eniga om det, så modellen kan svälja det
    # genom att göra rummet nyss så mycket större. Det ser inte suddigt ut.
    # Kontrollen byter därför kalibrering men behåller ARKits poser.
    lens = best.cameras[next(iter(best.cameras))]
    swapped = np.array([[lens.focal_length_x, 0.0, lens.principal_point_x],
                        [0.0, lens.focal_length_y, lens.principal_point_y],
                        [0.0, 0.0, 1.0]], np.float32)
    control = []
    for image in best.images.values():
        frame = frames.get(image.name)
        if frame is None:
            continue
        seen = [(point.xy, cloud[point.point3D_id])
                for point in image.points2D if point.has_point3D()]
        if not seen:
            continue
        frame.intrinsics = swapped
        pixels, _ = frame.project(
            scale * np.asarray([xyz for _, xyz in seen], np.float32) @ rotation.T + offset)
        control.append(np.linalg.norm(
            pixels - np.asarray([xy for xy, _ in seen], np.float32), axis=1))
    control = np.concatenate(control)

    print(f"ARKits poser MEN COLMAPs kalibrering: median {np.median(control):.1f} px")
    print(f"ARKit sa f={first.intrinsics[0, 0]:.1f}, COLMAP säger "
          f"f={lens.focal_length_x:.1f}. Faller talet mycket här var felet "
          "kalibrering — inte poser, och då suddar det inte.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
