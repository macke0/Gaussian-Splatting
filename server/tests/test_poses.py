"""Bytet från ARKits poser till COLMAPs.

Det som testas är omräkningen, inte SfM. Rekonstruktionen kräver pycolmap och
minuter av CPU, men den delen är COLMAPs ansvar. Vår del är de fyra tecknen
mellan hålkameran och ARKits Y-upp, och där syns ett fel först efter en hel
träning — alltså mäts det här i stället.

Testet går baklänges: från kända ARKit-poser byggs precis det COLMAP skulle ha
lämnat ifrån sig om det löste samma rum, uttryckt i en egen värld som är vriden,
flyttad och skalad. Kommer de ursprungliga poserna tillbaka ut är omräkningen
rätt.
"""

from __future__ import annotations

import numpy as np
import pytest

from spatialfit_server.bundle import Keyframe, ScanBundle
from spatialfit_server.mesh import SceneMesh
from spatialfit_server.poses import _keyframe, refined, umeyama

FLIP = np.diag([1.0, -1.0, -1.0])


class _Rotation:
    def __init__(self, matrix):
        self._matrix = matrix

    def matrix(self):
        return self._matrix


class _Pose:
    def __init__(self, rotation, translation):
        self.rotation = _Rotation(rotation)
        self.translation = translation


class _Image:
    """Så mycket av pycolmaps ``Image`` som omräkningen rör vid."""

    def __init__(self, name, rotation, translation):
        self.name = name
        self.camera_id = 1
        self.points2D = []
        self._pose = _Pose(rotation, translation)

    def cam_from_world(self):
        return self._pose

    def projection_center(self):
        return -self._pose.rotation.matrix().T @ self._pose.translation


class _Lens:
    focal_length_x = 812.0
    focal_length_y = 811.0
    principal_point_x = 640.5
    principal_point_y = 480.5


class _Reconstruction:
    cameras = {1: _Lens()}


def _rotation(yaw: float, pitch: float = 0.0) -> np.ndarray:
    around_y = np.array([[np.cos(yaw), 0, np.sin(yaw)],
                         [0, 1, 0],
                         [-np.sin(yaw), 0, np.cos(yaw)]])
    around_x = np.array([[1, 0, 0],
                         [0, np.cos(pitch), -np.sin(pitch)],
                         [0, np.sin(pitch), np.cos(pitch)]])
    return around_y @ around_x


def _keyframes() -> list[Keyframe]:
    """Sex kameror på en ring, med olika riktning — ARKits värld, i meter."""
    frames = []
    for identifier, angle in enumerate(np.linspace(0, 2 * np.pi, 6, endpoint=False)):
        world_from_camera = np.eye(4, dtype=np.float32)
        world_from_camera[:3, :3] = _rotation(angle, 0.2 * np.sin(angle))
        world_from_camera[:3, 3] = [1.4 * np.cos(angle), 1.5, 1.4 * np.sin(angle)]

        frames.append(Keyframe(
            id=identifier,
            camera_from_world=np.linalg.inv(world_from_camera).astype(np.float32),
            intrinsics=np.array([[900.0, 0, 640], [0, 900.0, 480], [0, 0, 1]],
                                np.float32),
            image_size=np.array([1280, 960], np.float32),
            depth_size=np.array([0, 0], np.int32),
            image=np.zeros((4, 4, 3), np.uint8),
            depth=None))
    return frames


def _as_colmap(frames, rotation, scale, offset):
    """Samma kameror sedda ur COLMAPs enhetslösa, vridna värld."""
    images = []
    for frame in frames:
        turn = FLIP @ frame.camera_from_world[:3, :3] @ rotation
        centre = rotation.T @ (frame.position - offset) / scale
        images.append(_Image(f"kf{frame.id}.jpg", turn, -turn @ centre))
    return images


def test_umeyama_hittar_tillbaka_till_rotation_skala_och_flytt():
    source = np.random.default_rng(0).normal(size=(20, 3))
    turn, scale, move = _rotation(0.7, -0.3), 2.5, np.array([1.0, -2.0, 0.5])
    target = scale * source @ turn.T + move

    found_rotation, found_scale, found_offset = umeyama(source, target)

    assert found_scale == pytest.approx(scale, rel=1e-6)
    assert np.allclose(found_rotation, turn, atol=1e-6)
    assert np.allclose(found_offset, move, atol=1e-6)


def test_colmaps_poser_raknas_tillbaka_till_arkits_varld():
    """Fyra tecken kan slarvas bort på vägen. Här ska allihop komma tillbaka."""
    frames = _keyframes()
    turn, scale, move = _rotation(-1.1, 0.4), 0.37, np.array([2.0, 0.5, -1.5])
    images = _as_colmap(frames, turn, scale, move)

    rotation, found_scale, offset = umeyama(
        np.asarray([image.projection_center() for image in images]),
        np.asarray([frame.position for frame in frames]))
    assert found_scale == pytest.approx(scale, rel=1e-5)

    for frame, image in zip(frames, images):
        rebuilt = _keyframe(frame, image, _Reconstruction(),
                            rotation, found_scale, offset)
        assert np.allclose(rebuilt.camera_from_world, frame.camera_from_world,
                           atol=1e-4)


def test_kalibreringen_kommer_fran_colmap_inte_fran_arkit():
    """COLMAP löste poserna med sin egen lins; ARKits skulle göra dem oense."""
    frame = _keyframes()[0]
    turn, scale, move = np.eye(3), 1.0, np.zeros(3)
    image = _as_colmap([frame], turn, scale, move)[0]

    rebuilt = _keyframe(frame, image, _Reconstruction(), turn, scale, move)

    assert rebuilt.intrinsics[0, 0] == pytest.approx(_Lens.focal_length_x)
    assert rebuilt.intrinsics[1, 2] == pytest.approx(_Lens.principal_point_y)


def test_for_fa_foton_faller_tillbaka_pa_arkit(tmp_path):
    """Ett halvdussin bilder är ingen rekonstruktion, och SfM ska inte ens köras."""
    bundle = ScanBundle(mesh=SceneMesh(np.zeros((0, 3), np.float32),
                                       np.zeros((0, 3), np.uint32)),
                        keyframes=_keyframes())

    assert refined(bundle, tmp_path) is None
