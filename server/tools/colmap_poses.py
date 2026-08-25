"""Skriver om en skanning med COLMAPs kameraplaceringar i stället för ARKits.

``pose_check`` visade att ARKits poser missar sin egen bildpunkt med 13 pixlar
medan COLMAP klarar 0,8. Det här verktyget byter ut dem. Resultatet är en vanlig
skanningsmapp, så allt nedströms — träning, mätning, bakning — fungerar utan att
en enda rad ändras.

Poserna läggs in i ARKITS värld, inte i COLMAPs egen. Skälet är att skalan måste
komma någonstans ifrån: COLMAP vet hur rummet SER ut men inte hur stort det är,
och det är LiDAR som mäter meter. Umeyama-passningen ger rotation, förflyttning
och en skalfaktor som tar COLMAP till metrar; djupkartorna behåller därmed sin
mening och ``measured_points`` byggs om av sig själv ur de nya poserna.

    python tools/colmap_poses.py <skanning> <colmap-mapp> <ny skanning>

Kontrollen sist är det viktiga i filen. Går en pose fel väg — och det finns fyra
tecken att slarva med mellan COLMAPs hålkamera och ARKits Y-upp — så syns det
inte i någon bild förrän efter en hel träning. Reprojektionsfelet med de NYA
poserna räknas därför ut på plats: landar det nära COLMAPs eget tal är bytet
rätt gjort, och står det kvar vid ARKits är det något som pekar åt fel håll.
"""
import json
import shutil
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from pose_check import _umeyama  # noqa: E402


def _largest(directory: Path):
    """Största delrekonstruktionen. Ett rum spricker om en vägg är för kal."""
    import pycolmap

    parts = [pycolmap.Reconstruction(str(path)) for path in sorted(directory.iterdir())
             if (path / "cameras.bin").exists() or (path / "cameras.txt").exists()]
    if not parts:
        raise FileNotFoundError(f"ingen rekonstruktion i {directory}")
    return max(parts, key=lambda part: part.num_reg_images())


def main(argv: list[str] | None = None) -> int:
    arguments = (argv if argv is not None else sys.argv[1:])
    if len(arguments) < 3:
        print(__doc__.strip().splitlines()[-8], file=sys.stderr)
        return 2

    scan, colmap, target = (Path(name) for name in arguments[:3])
    bundle = ScanBundle.load(scan)
    frames = {f"kf{frame.id}.jpg": frame for frame in bundle.keyframes}
    best = _largest(colmap)

    # Samma passning som i ``pose_check``: COLMAPs enhetslösa värld → meter.
    pairs = [(image.projection_center(), frames[image.name].position)
             for image in best.images.values() if image.name in frames]
    rotation, scale, offset = _umeyama(
        np.asarray([centre for centre, _ in pairs]),
        np.asarray([position for _, position in pairs]))

    # Hålkamera → ARKits kamerarum. ARKit har Y uppåt och Z bakåt, COLMAP tvärtom,
    # och matrisen är sin egen invers.
    flip = np.diag([1.0, -1.0, -1.0])

    entries, kept = [], []
    for image in best.images.values():
        frame = frames.get(image.name)
        if frame is None:
            continue

        pose = image.cam_from_world()
        # x_kamera(m) = R_c·R^T·x_värld + (s·t_c − R_c·R^T·t). Skalan hör hemma i
        # förflyttningen, aldrig i rotationen — en skalad rotation är ingen pose.
        turn = pose.rotation.matrix() @ rotation.T
        move = scale * pose.translation - turn @ offset

        camera_from_world = np.eye(4, dtype=np.float32)
        camera_from_world[:3, :3] = flip @ turn
        camera_from_world[:3, 3] = flip @ move

        # COLMAP löste poserna med SIN kalibrering; att blanda in ARKits skulle
        # göra dem inbördes oense igen.
        camera = best.cameras[image.camera_id]
        intrinsics = np.array(
            [[camera.focal_length_x, 0.0, camera.principal_point_x],
             [0.0, camera.focal_length_y, camera.principal_point_y],
             [0.0, 0.0, 1.0]], np.float32)

        entries.append({
            "id": frame.id,
            "imageSize": frame.image_size.tolist(),
            "depthSize": frame.depth_size.tolist(),
            # Swift skriver kolumnvis, så det ska skrivas tillbaka kolumnvis.
            "cameraFromWorldColumns": camera_from_world.T.tolist(),
            "intrinsicsColumns": intrinsics.T.tolist(),
        })
        kept.append((frame, camera_from_world, intrinsics, image))

    # COLMAP räknar upp bilderna i sin egen ordning. Måtten plockar var tionde
    # keyframe, så en omkastad lista jämför andra foton än originalet gör.
    order = np.argsort([entry["id"] for entry in entries])
    entries = [entries[index] for index in order]
    kept = [kept[index] for index in order]

    target.mkdir(parents=True, exist_ok=True)
    for frame, *_ in kept:
        for suffix in (".jpg", ".depth"):
            source = scan / f"kf{frame.id}{suffix}"
            if source.exists():
                shutil.copy2(source, target / source.name)
    shutil.copy2(scan / "room.mesh", target / "room.mesh")
    (target / "keyframes.json").write_text(json.dumps(entries))

    lens = best.cameras[kept[0][3].camera_id]
    print(f"{len(kept)} av {len(frames)} keyframes skrevs om till {target}")
    print(f"skala {scale:.4f}, {lens.model.name} f={lens.focal_length_x:.1f} "
          f"(ARKit sa {bundle.keyframes[0].intrinsics[0, 0]:.1f}), "
          f"förvrängning {list(lens.params)[3:]}")

    # Kontrollen. Samma punkter, samma bildpunkter, men de NYA poserna.
    cloud = {number: point.xyz for number, point in best.points3D.items()}
    misses = []
    for frame, camera_from_world, intrinsics, image in kept:
        seen = [(point.xy, cloud[point.point3D_id])
                for point in image.points2D if point.has_point3D()]
        if not seen:
            continue
        frame.camera_from_world = camera_from_world
        frame.intrinsics = intrinsics
        world = np.asarray([xyz for _, xyz in seen], np.float32)
        pixels, _ = frame.project(scale * world @ rotation.T + offset)
        misses.append(np.linalg.norm(
            pixels - np.asarray([xy for xy, _ in seen], np.float32), axis=1))

    miss = np.concatenate(misses)
    print(f"KONTROLL med de nya poserna: median {np.median(miss):.2f} px, "
          f"p90 {np.percentile(miss, 90):.2f} px")
    print("ARKit låg på 13,0 px. Står talet kvar där pekar en pose åt fel håll.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
