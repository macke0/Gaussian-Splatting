"""Hela vägen: en syntetisk skanning in, baked.mesh och baked.png ut.

Testet finns för att fånga när trimesh eller xatlas byter API under fötterna på
oss. Det bakar ett litet rum, så det får kosta någon sekund.
"""

from __future__ import annotations

import json

import numpy as np
import trimesh
from PIL import Image

from spatialfit_server.bundle import connected_surface
from spatialfit_server.mesh import SceneMesh, TexturedMesh
from spatialfit_server.pipeline import bake_room


def write_scan(directory, wall_color=(180, 90, 60)) -> None:
    """Ett kubiskt rum sett inifrån, fotograferat från mitten."""
    room = trimesh.creation.box(extents=(4.0, 2.5, 4.0))
    # LiDAR ger tusentals små trianglar. En kub med åtta hörn är inte bara
    # snabbare — den kollapsar under utjämningen, och testet ska likna det som
    # faktiskt bakas.
    for _ in range(4):
        room = room.subdivide()
    positions = np.asarray(room.vertices, np.float32)
    faces = np.asarray(room.faces, np.uint32)

    mesh = (b"SFMESH01"
            + np.array([len(positions), faces.size], "<u4").tobytes()
            + positions.astype("<f4").tobytes()
            + faces.reshape(-1).astype("<u4").tobytes())
    (directory / "room.mesh").write_bytes(mesh)

    size = 128
    focal = 90.0
    intrinsics = np.array([[focal, 0, size / 2],
                           [0, focal, size / 2],
                           [0, 0, 1]], np.float32)

    entries = []
    for identifier, angle in enumerate(np.linspace(0, 2 * np.pi, 8, endpoint=False)):
        world_from_camera = np.eye(4, dtype=np.float32)
        # Kameran står i mitten och snurrar runt sin egen y-axel.
        world_from_camera[:3, :3] = trimesh.transformations.rotation_matrix(
            angle, [0, 1, 0])[:3, :3]
        camera_from_world = np.linalg.inv(world_from_camera)

        Image.fromarray(np.tile(np.array(wall_color, np.uint8), (size, size, 1))).save(
            directory / f"kf{identifier}.jpg")
        entries.append({
            "id": identifier,
            "depthSize": [0, 0],
            "imageSize": [size, size],
            "cameraFromWorldColumns": camera_from_world.T.tolist(),
            "intrinsicsColumns": intrinsics.T.tolist(),
        })

    (directory / "keyframes.json").write_text(json.dumps(entries))


def test_en_flaga_som_svavar_i_rummet_raknas_inte_som_yta():
    """Det som ARKit lämnar efter sig mitt i luften ska inte gå att så på."""
    room = trimesh.creation.box(extents=(4.0, 2.5, 4.0)).subdivide().subdivide()
    flake = trimesh.creation.box(extents=(0.1, 0.1, 0.1))
    flake.apply_translation([0.0, 0.0, 0.0])
    both = trimesh.util.concatenate([room, flake])

    positions, faces = connected_surface(
        SceneMesh(np.asarray(both.vertices, np.float32),
                  np.asarray(both.faces, np.uint32)))

    # Flagan låg i mitten; efter städningen finns inget kvar där inne.
    distance = np.linalg.norm(positions, axis=1)
    assert distance.min() > 0.5
    assert len(faces) == len(room.faces)


def test_en_yta_utan_flagor_lamnas_orord():
    room = trimesh.creation.box(extents=(4.0, 2.5, 4.0)).subdivide()

    positions, faces = connected_surface(
        SceneMesh(np.asarray(room.vertices, np.float32),
                  np.asarray(room.faces, np.uint32)))

    assert len(faces) == len(room.faces)
    assert len(positions) == len(room.vertices)


def test_ett_rum_bakas_till_mesh_och_textur(tmp_path):
    write_scan(tmp_path)

    baked = bake_room(tmp_path, atlas_size=256, target_faces=2000)

    assert baked.triangle_count > 0
    assert baked.texture.shape == (256, 256, 3)
    # Ett rum fotograferat från mitten ska vara målat nästan överallt.
    assert baked.seen_fraction > 0.5


def test_resultatet_gar_att_lasa_tillbaka(tmp_path):
    write_scan(tmp_path)
    output = tmp_path / "ut"

    bake_room(tmp_path, atlas_size=128, target_faces=1000).write(output)

    decoded = TexturedMesh.decode((output / "baked.mesh").read_bytes())
    assert len(decoded.positions) == len(decoded.uvs) == len(decoded.normals)
    assert decoded.indices.max() < len(decoded.positions)
    assert np.all((decoded.uvs >= -1e-4) & (decoded.uvs <= 1 + 1e-4))
    assert Image.open(output / "baked.png").size == (128, 128)
