"""Gör om ett COLMAP-dataset till en skanningsmapp, så VÅR kedja kan köra på det.

Frågan verktyget finns för: är suddet vår DATA eller vår KOD? Måtten kan inte
skilja dem åt, för de mäter alltid båda på en gång. Det enda som kan är att byta
ut den ena och behålla den andra. Här byts datan: mipnerf360 är det dataset som
3DGS-artiklarna visar sina bilder på, med kameror lösta ur bilderna till
bråkdelen av en pixel. Blir vår kod skarp på det, är det vår data som är felet.
Blir den suddig även där, är det koden.

Resultatet är en vanlig skanningsmapp — ``room.mesh``, ``keyframes.json``,
``kfN.jpg`` — så träning, mätning och bakning fungerar utan att en rad ändras.

Tre saker måste översättas, och alla tre kan tyst förstöra försöket:

**Kamerarummet.** COLMAP räknar med hålkameran (Y ned, Z fram), ARKit med Y upp
och Z bak. Skillnaden är två teckenbyten, och gör man dem inte syns felet först
efter en hel träning. ``bundle.Keyframe.project`` vänder tillbaka dem, så en
felvänd pose ger ett reprojektionsfel i storleksordningen halva bilden — därför
mäts det på plats sist i filen i stället för att antas.

**Skalan.** En rekonstruktion ur bara bilder vet hur rummet SER ut men inte hur
stort det är. Våra klämmor är i meter (``MAXIMUM_DRIFT`` 2 cm, tjockleken 1 mm),
så ett enhetslöst rum skulle antingen klämmas till en klump eller inte alls.
Scenen skalas därför så att dess låda blir lika stor som ett riktigt rum. Talet
är en uppskattning och inget annat, men bara storleksordningen behöver stämma
för att klämmorna ska betyda samma sak här som hemma.

**Ytan.** Vi har LiDAR, mipnerf360 har det inte. Det närmaste är COLMAPs
punktmoln, som blir en yta genom att fyllas i ett rutnät och marschera kuber. Den
ytan är GROVARE än vår, vilket är ett handikapp för oss i det här försöket och
ska läsas som det: blir vår kod bra ändå, väger resultatet tyngre.

    python tools/referens_skanning.py <colmap-dataset> <ny skanning> [--bredd 1600]
"""
import argparse
import json
import shutil
import struct
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.mesh import SCENE_MAGIC  # noqa: E402

#: Så stor görs scenens låda, mätt över diagonalen. Ett vardagsrum med möbler
#: ligger kring det här, och siffran behöver bara stämma till storleksordningen:
#: den bestämmer vad två centimeters drift BETYDER i den här scenen.
ROOM_DIAGONAL = 10.0

#: Rutnätets sida när punktmolnet görs om till en yta. Fint nog att en soffkant
#: överlever, grovt nog att SfM-molnets hål inte blir till öar.
VOXEL = 0.06

#: Punkter längre bort än så här många medianavstånd från mitten är SfM-skräp —
#: enstaka felmatchningar hamnar kilometervis bort och skulle annars ensamma
#: bestämma både skalan och lådan.
OUTLIER_DISTANCE = 3.0


def _colmap_to_arkit(rotation: np.ndarray, translation: np.ndarray) -> np.ndarray:
    """COLMAPs värld→kamera som ARKits värld→kamera.

    Båda är värld→kamera; det som skiljer är kamerarummets axlar. ARKit har Y upp
    och Z bak där hålkameran har Y ned och Z fram, alltså ett teckenbyte på två
    rader — inte en transponering, och inte något som rör världen.
    """
    flip = np.diag([1.0, -1.0, -1.0])
    matrix = np.eye(4)
    matrix[:3, :3] = flip @ rotation
    matrix[:3, 3] = flip @ translation
    return matrix


def _surface(points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """Punktmolnet som en yta med trianglar, vilket sådden kräver."""
    import trimesh

    mesh = trimesh.voxel.ops.points_to_marching_cubes(points, pitch=VOXEL)
    return (np.asarray(mesh.vertices, np.float32),
            np.asarray(mesh.faces, np.uint32))


def _write_mesh(path: Path, positions: np.ndarray, indices: np.ndarray) -> None:
    path.write_bytes(SCENE_MAGIC
                     + struct.pack("<II", len(positions), indices.size)
                     + positions.astype("<f4").tobytes()
                     + indices.reshape(-1).astype("<u4").tobytes())


def build(dataset: Path, destination: Path, width: int) -> None:
    import pycolmap

    reconstruction = pycolmap.Reconstruction(str(_model(dataset)))
    images = _image_directory(dataset)
    print(f"läser {len(reconstruction.images)} bilder och "
          f"{len(reconstruction.points3D)} punkter ur {dataset}")

    points = np.array([point.xyz for point in reconstruction.points3D.values()])
    colours = np.array([point.color for point in reconstruction.points3D.values()])

    # Skräpet bort FÖRE skalan räknas ut, annars sätter en enda felmatchad punkt
    # hela rummets storlek.
    centre = np.median(points, axis=0)
    distance = np.linalg.norm(points - centre, axis=1)
    keep = distance < np.median(distance) * OUTLIER_DISTANCE
    points, colours = points[keep], colours[keep]
    print(f"behåller {keep.sum()} av {len(keep)} punkter efter gallring")

    span = points.max(axis=0) - points.min(axis=0)
    scale = ROOM_DIAGONAL / float(np.linalg.norm(span))
    points = ((points - centre) * scale).astype(np.float32)
    print(f"skalar med {scale:.4f}; rummet blir "
          f"{' × '.join(f'{value:.1f}' for value in span * scale)} m")

    destination.mkdir(parents=True, exist_ok=True)
    positions, indices = _surface(points)
    _write_mesh(destination / "room.mesh", positions, indices)
    print(f"ytan: {len(positions)} hörn, {len(indices)} trianglar")

    entries = []
    for number, image in enumerate(reconstruction.images.values()):
        source = images / image.name
        if not source.exists():
            continue

        photo = Image.open(source).convert("RGB")
        shrink = width / photo.width
        photo = photo.resize((width, round(photo.height * shrink)), Image.LANCZOS)
        photo.save(destination / f"kf{number}.jpg", quality=95)

        camera = reconstruction.cameras[image.camera_id]
        pose = image.cam_from_world()
        rotation = np.asarray(pose.rotation.matrix())

        # Världen flyttades och skalades ovan, och posen måste följa med. Med
        # p' = (p − mitten)·s blir kamerans led R·p + t till R·p' + s(R·mitten + t)
        # när även kamerarummet skalas — riktningen är alltså orörd, hela
        # ändringen sitter i förflyttningen.
        translation = scale * (rotation @ centre + np.asarray(pose.translation))
        matrix = _colmap_to_arkit(rotation, translation)

        entries.append({
            "id": number,
            "imageSize": [photo.width, photo.height],
            "depthSize": [0, 0],
            # Swift kodar kolumnvis, och ``ScanBundle`` transponerar tillbaka.
            "cameraFromWorldColumns": matrix.T.tolist(),
            "intrinsicsColumns": _intrinsics(camera, shrink).T.tolist(),
        })

    (destination / "keyframes.json").write_text(json.dumps(entries))
    print(f"skrev {len(entries)} keyframes till {destination}")
    _verify(destination, points, colours)


def _intrinsics(camera, shrink: float) -> np.ndarray:
    """Kamerans inre som en 3×3, skalad till den storlek fotot sparades i."""
    values = dict(zip(camera.params_info.split(", "), camera.params))
    focal = values.get("f")
    matrix = np.array([[values.get("fx", focal), 0.0, values["cx"]],
                       [0.0, values.get("fy", focal), values["cy"]],
                       [0.0, 0.0, 1.0]])
    matrix[:2] *= shrink
    return matrix


def _model(dataset: Path) -> Path:
    for candidate in (dataset / "sparse" / "0", dataset / "sparse", dataset):
        if (candidate / "cameras.bin").exists() or (candidate / "cameras.txt").exists():
            return candidate
    raise SystemExit(f"hittar ingen COLMAP-modell under {dataset}")


def _image_directory(dataset: Path) -> Path:
    for name in ("images", "images_2", "images_4"):
        if (dataset / name).is_dir():
            return dataset / name
    raise SystemExit(f"hittar inga bilder under {dataset}")


def _verify(destination: Path, points: np.ndarray, colours: np.ndarray) -> None:
    """Projicerar punktmolnet med de skrivna poserna och mäter felet.

    Det här är filens viktigaste del. Vänds en axel fel går allt annat igenom
    utan ett knyst och först en hel träning senare syns att det blev grumligt.
    Punkterna kommer ur samma rekonstruktion som poserna, så de MÅSTE landa där
    de syns: några få pixlar är rätt, hundratals betyder fel tecken någonstans.
    """
    bundle = ScanBundle.load(destination)
    inside = []
    for frame in bundle.keyframes[:40]:
        pixels, depth = frame.project(points)
        width, height = frame.image_size
        visible = ((depth > 0) & (pixels[:, 0] >= 0) & (pixels[:, 0] < width)
                   & (pixels[:, 1] >= 0) & (pixels[:, 1] < height))
        inside.append(visible.mean())

    share = float(np.mean(inside))
    print(f"kontroll: {share:.1%} av punkterna hamnar i bild "
          f"({len(bundle.keyframes)} keyframes lästes tillbaka)")
    if share < 0.15:
        raise SystemExit("för få punkter i bild — en axel pekar åt fel håll")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--bredd", type=int, default=1600,
                        help="fotobredd i den nya skanningen; våra egna "
                             "keyframes ligger kring 1900 px")
    arguments = parser.parse_args()
    if arguments.destination.exists():
        shutil.rmtree(arguments.destination)
    build(arguments.dataset, arguments.destination, arguments.bredd)


if __name__ == "__main__":
    main()
