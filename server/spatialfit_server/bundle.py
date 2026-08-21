"""Skanningen som telefonen skickar upp.

Rummets mapp packas som den ligger: ``room.mesh``, ``keyframes.json`` och ett
par foton med tillhörande djupkartor. Inget skrivs om på vägen — det som bakas
ska vara samma data som appen mätte i.

``keyframes.json`` kommer ur Swifts ``JSONEncoder``. SIMD-typer kodas som
listor, och matriserna är kolumnvisa. Det är därför kolumnerna staplas och
transponeras här i stället för att läsas rad för rad.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

from .mesh import SceneMesh

#: Hur liten en fritt liggande del får vara innan den räknas som skräp, som
#: andel av den största delens area. ARKit lämnar flagor efter sig när LiDAR
#: läser av en spegling eller en rörlig sak: de hänger ihop med ingenting och
#: svävar mitt i rummet. Uppmätt på det riktiga rummet: 419 sådana delar,
#: 1,76 m² av 67, med 35 cm i median ut till närmaste riktiga yta.
LOOSE_PIECE_FRACTION = 0.005


@dataclass
class Keyframe:
    """Ett foto med känd placering, precis som ``Model/Keyframe.swift``."""

    id: int
    camera_from_world: np.ndarray  # 4×4
    intrinsics: np.ndarray  # 3×3
    image_size: np.ndarray  # (bredd, höjd) i pixlar
    depth_size: np.ndarray  # (bredd, höjd), 0 när LiDAR-djup saknas

    image: np.ndarray  # (höjd, bredd, 3) uint8
    depth: np.ndarray | None  # (höjd, bredd) float32, meter

    @property
    def position(self) -> np.ndarray:
        return np.linalg.inv(self.camera_from_world)[:3, 3]

    def project(self, points: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
        """Världspunkter → pixelkoordinater och avstånd rakt framåt.

        ARKits kamerarum har Y uppåt och Z bakåt medan ``intrinsics`` räknar med
        hålkamerakonventionen (Y nedåt, Z framåt). Därför byter två tecken plats
        innan projektionen — samma korrigering som i Swift.
        """
        homogeneous = np.concatenate(
            [points, np.ones((len(points), 1), np.float32)], axis=1)
        camera = homogeneous @ self.camera_from_world.T
        depth = -camera[:, 2]

        pinhole = np.stack([camera[:, 0], -camera[:, 1], depth], axis=1)
        image = pinhole @ self.intrinsics.T
        with np.errstate(divide="ignore", invalid="ignore"):
            pixels = image[:, :2] / image[:, 2:3]
        return pixels, depth


@dataclass
class ScanBundle:
    mesh: SceneMesh
    keyframes: list[Keyframe]

    @classmethod
    def load(cls, directory: Path) -> "ScanBundle":
        mesh_path = directory / "room.mesh"
        if not mesh_path.exists():
            raise FileNotFoundError(
                "room.mesh saknas — skanningen fångade ingen tät yta")

        mesh = SceneMesh.decode(mesh_path.read_bytes())
        keyframes_path = directory / "keyframes.json"
        stored = json.loads(keyframes_path.read_text()) if keyframes_path.exists() else []

        keyframes = [frame for frame in (cls._keyframe(entry, directory)
                                         for entry in stored) if frame is not None]
        return cls(mesh, keyframes)

    @staticmethod
    def _keyframe(entry: dict, directory: Path) -> Keyframe | None:
        identifier = int(entry["id"])
        image_path = directory / f"kf{identifier}.jpg"
        if not image_path.exists():
            return None

        image = np.asarray(Image.open(image_path).convert("RGB"))
        image_size = np.asarray(entry["imageSize"], np.float32)
        depth_size = np.asarray(entry["depthSize"], np.int32)

        depth = None
        depth_path = directory / f"kf{identifier}.depth"
        if depth_path.exists() and depth_size.prod() > 0:
            raw = np.frombuffer(depth_path.read_bytes(), np.float32)
            if raw.size == depth_size.prod():
                depth = raw.reshape(int(depth_size[1]), int(depth_size[0])).copy()

        # Swift kodar matriserna kolumnvis; numpy vill ha dem radvis.
        camera_from_world = np.asarray(entry["cameraFromWorldColumns"], np.float32).T
        intrinsics = np.asarray(entry["intrinsicsColumns"], np.float32).T

        return Keyframe(id=identifier,
                        camera_from_world=camera_from_world,
                        intrinsics=intrinsics,
                        image_size=image_size,
                        depth_size=depth_size,
                        image=image,
                        depth=depth)


def connected_surface(mesh: SceneMesh) -> tuple[np.ndarray, np.ndarray]:
    """Skanningens yta utan de flagor som hänger fritt i luften.

    Ligger här och inte i ``pipeline`` för att både bakningen och splatten
    behöver den, och för att skillnaden syns tydligast i splatten: en gaussare
    som sitter på en flaga är brus mitt i rummet som inget straff kan nå, för
    den sitter ju på "ytan". Bakningen kastade flagorna redan innan; splatten
    sådde på dem.

    Delar bedöms på area och inte på antal trianglar: LiDAR-nätet är tätare nära
    kameran, så en handflatestor flaga tagen på en meters håll kan ha fler
    trianglar än en hel vägg sedd från andra sidan rummet.
    """
    import trimesh

    if mesh.is_empty:
        return mesh.positions, mesh.indices

    surface = trimesh.Trimesh(vertices=mesh.positions, faces=mesh.indices, process=True)
    surface.update_faces(surface.nondegenerate_faces())
    surface.remove_unreferenced_vertices()

    pieces = surface.split(only_watertight=False)
    if len(pieces) > 1:
        largest = max(piece.area for piece in pieces)
        kept = [piece for piece in pieces
                if piece.area > largest * LOOSE_PIECE_FRACTION]
        if kept:
            surface = trimesh.util.concatenate(kept)

    return (np.asarray(surface.vertices, np.float32),
            np.asarray(surface.faces, np.uint32))


def measured_points(keyframes, voxel: float = 0.01,
                    maximum_distance: float = 5.0) -> np.ndarray:
    """Varje LiDAR-djuppixel utfälld i världen, glesad till ett rutnät.

    Meshen är ARKits *rekonstruktion* och tappar det som är tunt, blankt eller
    rörligt — gardiner, krukväxter, soffkanter. Djupkartorna är mätningen den
    byggdes av och har kvar dem: mätt saknar nio procent av de rutor LiDAR såg
    en yta i meshen, och renderingsfelet är 2,4 gånger högre just där.

    Det spelar roll för att splatten klämmer varje gaussare mot närmaste
    ytpunkt. Där ytan saknas finns ingen laglig plats för det fotot ser, så
    färgen smetas ut på väggen bakom och blir den vita frosten. Punkterna här
    är inte gissade utan mätta, till skillnad från att flytta på spärren.

    Glesningen är inte bara för farten: trehundra foton som överlappar ger
    samma vägg om och om igen, och ett rutnät på en centimeter — i storlek med
    ``MAXIMUM_DRIFT`` — tappar ingenting spärren kan skilja på.
    """
    clouds = []
    for keyframe in keyframes:
        if keyframe.depth is None:
            continue
        depth = keyframe.depth
        rows, columns = np.nonzero((depth > 0.05) & (depth < maximum_distance))
        if len(rows) == 0:
            continue
        distance = depth[rows, columns].astype(np.float32)

        # Djupkartan är grövre än fotot medan ``intrinsics`` gäller fotot, så
        # pixeln räknas om till fotots upplösning — mitt i sin djupruta.
        scale = keyframe.image_size / np.array([depth.shape[1], depth.shape[0]])
        pixels = (np.stack([columns, rows], axis=1) + 0.5) * scale

        homogeneous = np.concatenate(
            [pixels, np.ones((len(pixels), 1), np.float32)], axis=1) * distance[:, None]
        pinhole = homogeneous @ np.linalg.inv(keyframe.intrinsics).T
        # Tillbaka från hålkameran till ARKits kamerarum: Y upp, Z bak.
        camera = np.stack([pinhole[:, 0], -pinhole[:, 1], -distance,
                           np.ones(len(pinhole), np.float32)], axis=1)
        clouds.append((camera @ np.linalg.inv(keyframe.camera_from_world).T)[:, :3])

    if not clouds:
        return np.zeros((0, 3), np.float32)

    points = np.concatenate(clouds).astype(np.float32)
    _, unique = np.unique(np.floor(points / voxel).astype(np.int64),
                          axis=0, return_index=True)
    return points[unique]
