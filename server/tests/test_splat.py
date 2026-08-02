"""Splattens CPU-delar: poser, startpunkter och färgkällans val.

Själva träningen kräver CUDA och testas inte här. Det som går att testa utan GPU
är också det som lättast går sönder tyst: en pose som glidit ur led ger ett
vackert renderat men fel rum, och det syns inte i en förlustkurva.
"""

from __future__ import annotations

import numpy as np
import pytest
import trimesh

from spatialfit_server.bundle import Keyframe, ScanBundle
from spatialfit_server.mesh import SceneMesh
from spatialfit_server.pipeline import bake_room
from spatialfit_server.splat import _between, _poses, _seed


def keyframe(identifier: int, angle: float) -> Keyframe:
    world_from_camera = np.eye(4, dtype=np.float32)
    world_from_camera[:3, :3] = trimesh.transformations.rotation_matrix(
        angle, [0, 1, 0])[:3, :3]
    world_from_camera[:3, 3] = [np.cos(angle), 0.0, np.sin(angle)]

    return Keyframe(id=identifier,
                    camera_from_world=np.linalg.inv(world_from_camera).astype(np.float32),
                    intrinsics=np.eye(3, dtype=np.float32),
                    image_size=np.array([8, 8], np.float32),
                    depth_size=np.array([0, 0], np.int32),
                    image=np.zeros((8, 8, 3), np.uint8),
                    depth=None)


def bundle(frames: int = 3) -> ScanBundle:
    box = trimesh.creation.box(extents=(2.0, 2.0, 2.0))
    mesh = SceneMesh(positions=np.asarray(box.vertices, np.float32),
                     indices=np.asarray(box.faces, np.uint32))
    return ScanBundle(mesh=mesh,
                      keyframes=[keyframe(index, index * 0.5) for index in range(frames)])


def test_mellanpos_behaller_rotationen_ortonormal():
    first = keyframe(0, 0.0).camera_from_world
    second = keyframe(1, 1.2).camera_from_world

    middle = _between(first, second, 0.5)
    rotation = np.linalg.inv(middle)[:3, :3]

    # En rak interpolation av matriserna hade skalat rummet på vägen.
    assert np.allclose(rotation @ rotation.T, np.eye(3), atol=1e-5)
    assert np.isclose(np.linalg.det(rotation), 1.0, atol=1e-5)


def test_mellanpos_i_andarna_ar_ursprungsposerna():
    first = keyframe(0, 0.0).camera_from_world
    second = keyframe(1, 1.2).camera_from_world

    assert np.allclose(_between(first, second, 0.0), first, atol=1e-5)
    assert np.allclose(_between(first, second, 1.0), second, atol=1e-5)


def test_extra_vyer_skjuts_in_mellan_fotona():
    scan = bundle(frames=3)

    poses = _poses(scan, extra_views=2)

    # Tre foton, två inskjutna mellan varje par: 3 + 2·2.
    assert len(poses) == 7
    assert np.allclose(poses[0][1], scan.keyframes[0].camera_from_world)
    assert np.allclose(poses[3][1], scan.keyframes[1].camera_from_world)


def test_bara_fotonas_egna_poser_markeras_som_uppmatta():
    scan = bundle(frames=3)

    exact = [is_exact for _, _, is_exact in _poses(scan, extra_views=2)]

    # Djupkartan får bara följa med de poser den faktiskt mättes i.
    assert exact == [True, False, False, True, False, False, True]


def test_utan_extra_vyer_blir_det_bara_fotona():
    scan = bundle(frames=3)

    poses = _poses(scan, extra_views=0)

    assert len(poses) == 3
    assert all(is_exact for _, _, is_exact in poses)


def test_startpunkterna_ligger_pa_ytan_och_far_skala_av_grannen():
    scan = bundle()

    means, scales = _seed(scan, max_splats=1_000)

    assert len(means) == len(np.unique(scan.mesh.positions.reshape(-1, 3), axis=0))
    assert np.all(scales > 0)
    # En gaussare ska täcka ungefär halva vägen till grannen, aldrig hela rummet.
    assert scales.max() < 2.0


def test_startpunkterna_glesas_till_taket():
    scan = bundle()

    means, scales = _seed(scan, max_splats=4)

    assert len(means) == len(scales) == 4


def test_okand_fargkalla_avvisas(tmp_path):
    with pytest.raises(ValueError, match="färgkälla"):
        bake_room(tmp_path, color_source="splatt")
