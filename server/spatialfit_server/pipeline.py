"""Skanning in, bakat rum ut.

Ordningen är inte godtycklig. Ytan städas och glesas ut *innan* den veckas ut,
för att utvecklingen ska slippa ta hand om LiDAR:ns brus och för att atlasen
ska rymma trianglarna. Färgen läggs på sist, när varje texel vet var i rummet
den ligger.

Utjämningen här rör bara den yta rummet *visas* med. Måtten kommer aldrig
härifrån — de räknas ur ``CapturedRoom`` och ``Measurement/`` i appen, på
oförändrad data.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import trimesh
from PIL import Image

from . import atlas as atlas_module
from .bake import bake
from .bundle import ScanBundle
from .mesh import TexturedMesh

log = logging.getLogger(__name__)

#: Atlasens sida i texlar. 2048² räcker för ett rum fotograferat på 768 px.
DEFAULT_ATLAS_SIZE = 2048
#: Trianglar kvar efter utglesning. LiDAR ger gärna en halv miljon, vilket
#: varken atlasen eller telefonens renderare har någon nytta av.
DEFAULT_TARGET_FACES = 120_000

#: Var färgen kommer ifrån. ``blend`` väger ihop fotona direkt och kräver bara
#: CPU. ``splat`` tränar en gaussian splat först och målar med renderade vyer —
#: bättre på hål och skarvar, men kräver CUDA.
COLOR_SOURCES = ("blend", "splat")
DEFAULT_COLOR_SOURCE = "blend"


@dataclass
class BakedRoom:
    mesh: TexturedMesh
    texture: np.ndarray
    seen_fraction: float
    triangle_count: int

    def write(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "baked.mesh").write_bytes(self.mesh.encode())
        Image.fromarray(self.texture).save(directory / "baked.png")


def bake_room(directory: Path,
              atlas_size: int = DEFAULT_ATLAS_SIZE,
              target_faces: int = DEFAULT_TARGET_FACES,
              color_source: str = DEFAULT_COLOR_SOURCE) -> BakedRoom:
    if color_source not in COLOR_SOURCES:
        raise ValueError(f"okänd färgkälla {color_source!r}, välj en av {COLOR_SOURCES}")

    bundle = ScanBundle.load(directory)
    if bundle.mesh.is_empty:
        raise ValueError("skanningen innehåller ingen yta")
    if not bundle.keyframes:
        raise ValueError("skanningen innehåller inga foton att måla med")

    log.info("läste %d trianglar och %d foton",
             len(bundle.mesh.indices), len(bundle.keyframes))

    positions, faces = _cleaned(bundle.mesh.positions, bundle.mesh.indices, target_faces)
    log.info("städad yta: %d trianglar", len(faces))

    positions, uvs, faces, _ = atlas_module.unwrap(positions, faces)
    normals = atlas_module.vertex_normals(positions, faces)
    log.info("utvecklad till %d hörn", len(positions))

    unwrapped = atlas_module.rasterize(positions, normals, uvs, faces, atlas_size)
    log.info("atlasen täcker %.1f %% av ytan", unwrapped.coverage * 100)

    result = bake(unwrapped, _painting_views(bundle, color_source))
    log.info("%.1f %% av texlarna såg minst ett foto", result.seen_fraction * 100)

    return BakedRoom(mesh=TexturedMesh(positions=positions, normals=normals,
                                       uvs=uvs, indices=faces),
                     texture=result.texture,
                     seen_fraction=result.seen_fraction,
                     triangle_count=len(faces))


def _painting_views(bundle: "ScanBundle", color_source: str) -> list:
    """Fotona att måla med — antingen kamerans egna eller splattens renderade.

    Att låta splatten lämna ifrån sig ``Keyframe`` i stället för färg direkt gör
    att ``bake`` inte behöver veta att den finns: viktning, skymningstest och
    utfyllnad fungerar likadant på en renderad vy som på ett foto.
    """
    if color_source == "blend":
        return bundle.keyframes

    from .splat import synthetic_keyframes, train

    model = train(bundle)
    log.info("tränade %d gaussare", len(model))
    return synthetic_keyframes(model, bundle)


def _cleaned(positions: np.ndarray, faces: np.ndarray,
             target_faces: int) -> tuple[np.ndarray, np.ndarray]:
    """Slår ihop dubbletter, kastar skräptrianglar, jämnar ut och glesar."""
    mesh = trimesh.Trimesh(vertices=positions, faces=faces, process=True)
    mesh.update_faces(mesh.nondegenerate_faces())
    mesh.remove_unreferenced_vertices()

    # ARKit lämnar små flagor som svävar fritt. De blir egna öar i atlasen och
    # äter plats utan att synas.
    components = mesh.split(only_watertight=False)
    if len(components) > 1:
        largest = max(component.area for component in components)
        kept = [component for component in components if component.area > largest * 0.005]
        if kept:
            mesh = trimesh.util.concatenate(kept)

    # Ett svagt drag Laplace tar bort LiDAR:ns kornighet utan att runda av
    # hörnen så mycket att rummet tappar form.
    trimesh.smoothing.filter_taubin(mesh, lamb=0.5, nu=-0.53, iterations=8)

    mesh = _decimated(mesh, target_faces)

    return (np.asarray(mesh.vertices, np.float32),
            np.asarray(mesh.faces, np.uint32))


def _decimated(mesh: "trimesh.Trimesh", target_faces: int) -> "trimesh.Trimesh":
    """Glesar ut ytan om `fast-simplification` finns.

    Utglesningen är en optimering, inte en förutsättning: en otäljd yta bakas
    lika rätt, bara långsammare och till en större fil. Beroendet kräver
    Python 3.10, så en äldre tolk ska kunna baka ändå — men säga ifrån.
    """
    if len(mesh.faces) <= target_faces:
        return mesh

    try:
        return mesh.simplify_quadric_decimation(face_count=target_faces)
    except (ImportError, TypeError) as error:
        log.warning("hoppar över utglesningen (%s) — %d trianglar bakas som de är",
                    error, len(mesh.faces))
        return mesh
