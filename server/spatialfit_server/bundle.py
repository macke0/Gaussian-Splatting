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
