"""Splattens CPU-delar: poser, startpunkter och färgkällans val.

Själva träningen kräver CUDA och testas inte här. Det som går att testa utan GPU
är också det som lättast går sönder tyst: en pose som glidit ur led ger ett
vackert renderat men fel rum, och det syns inte i en förlustkurva.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest
import trimesh

from spatialfit_server.bundle import Keyframe, ScanBundle
from spatialfit_server.mesh import SceneMesh
from spatialfit_server.pipeline import bake_room
from spatialfit_server.atlas import vertex_normals
from spatialfit_server.splat import (MAXIMUM_DRIFT, SEED_THICKNESS, SH_DC, SplatModel,
                                     _aligned, _between, _poses, _pulled_to_surface,
                                     _seed, _trimmed, write_ply, write_spz)


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


def test_justerade_kameror_gar_fore_arkits_egna():
    scan = bundle(frames=3)
    # Splatten är skarp bara sett från de poser den tränades i. Renderas den ur
    # ARKits ursprungliga står bilden några centimeter fel mot ytan, och det
    # syns varken i förlusten eller i en atlas.
    refined = np.stack([frame.camera_from_world for frame in scan.keyframes])
    refined[:, 0, 3] += 0.05

    poses = _poses(scan, extra_views=1, refined=refined)

    assert np.allclose(poses[0][1], refined[0])
    assert np.allclose(poses[2][1], refined[1])
    # Även de inskjutna vyerna ska ligga mellan de justerade, inte de gamla.
    assert np.allclose(poses[1][1], _between(refined[0], refined[1], 0.5))


def seeded(scan: ScanBundle, max_splats: int):
    normals = vertex_normals(scan.mesh.positions, scan.mesh.indices)
    return _seed(scan.mesh.positions, normals, max_splats)


def test_startpunkterna_ligger_pa_ytan_och_far_skala_av_grannen():
    scan = bundle()

    means, scales, quats = seeded(scan, max_splats=1_000)

    assert len(means) == len(np.unique(scan.mesh.positions.reshape(-1, 3), axis=0))
    assert np.all(scales > 0)
    # En gaussare ska täcka ungefär halva vägen till grannen, aldrig hela rummet.
    assert scales.max() < 2.0
    assert np.allclose(np.linalg.norm(quats, axis=1), 1.0, atol=1e-5)


def test_startpunkterna_ar_skivor_och_inte_klot():
    scan = bundle()

    _, scales, _ = seeded(scan, max_splats=1_000)

    # Tredje axeln är den tunna: den ska peka ut ur väggen och nästan inget väga.
    assert np.allclose(scales[:, 2], scales[:, 0] * SEED_THICKNESS)
    assert np.all(scales[:, 2] < scales[:, 1])


def test_skivan_laggs_an_mot_ytan():
    """Den tunna axeln ska hamna längs normalen, oavsett vart den pekar."""
    normals = np.array([[0.0, 0.0, 1.0], [0.0, 0.0, -1.0],
                        [1.0, 0.0, 0.0], [0.0, 1.0, 0.0]], np.float32)

    quats = _aligned(normals)

    for quat, normal in zip(quats, normals):
        w, x, y, z = quat
        rotation = np.array([
            [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
            [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
            [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)]])
        assert np.allclose(rotation @ [0.0, 0.0, 1.0], normal, atol=1e-5)


def test_startpunkterna_glesas_till_taket():
    scan = bundle()

    means, scales, quats = seeded(scan, max_splats=4)

    assert len(means) == len(scales) == len(quats) == 4


def test_gaussare_som_svavar_ut_i_rummet_dras_tillbaka():
    from scipy.spatial import cKDTree

    # Lådans vägg ligger på x = 1. En gaussare mitt i rummet svävar alltså fritt.
    surface = np.unique(bundle().mesh.positions.reshape(-1, 3), axis=0).astype(np.float32)
    points = np.array([[1.0, 1.0, 1.0], [0.0, 0.0, 0.0]], np.float32)

    moved, pulled = _pulled_to_surface(points, cKDTree(surface), surface)

    assert pulled == 1
    # Den som redan satt på ytan rörs inte.
    assert np.allclose(moved[0], points[0])
    # Den fria hamnar precis vid gränsen, i den riktning den drev åt.
    assert np.isclose(np.linalg.norm(moved[1] - surface[np.argmin(
        np.linalg.norm(surface - points[1], axis=1))]), MAXIMUM_DRIFT, atol=1e-5)


def test_ytan_lamnas_ifred_nar_ingen_drivit():
    from scipy.spatial import cKDTree

    surface = np.unique(bundle().mesh.positions.reshape(-1, 3), axis=0).astype(np.float32)

    moved, pulled = _pulled_to_surface(surface.copy(), cKDTree(surface), surface)

    assert pulled == 0
    assert np.allclose(moved, surface)


def test_bortflugna_och_osynliga_gaussare_kastas():
    scan = bundle()
    # Lådan är 2×2×2 m kring origo, marginalen 1 m. Fyra gaussare: en i rummet,
    # en långt utanför, en genomskinlig, en precis på gränsen.
    logit = lambda alpha: float(np.log(alpha / (1 - alpha)))  # noqa: E731
    model = SplatModel(means=np.array([[0.0, 0.0, 0.0], [900.0, 0.0, 0.0],
                                       [0.1, 0.1, 0.1], [2.0, 0.0, 0.0]], np.float32),
                       quats=np.zeros((4, 4), np.float32),
                       scales=np.zeros((4, 3), np.float32),
                       opacities=np.array([logit(0.9), logit(0.9),
                                           logit(0.01), logit(0.9)], np.float32),
                       colors=np.zeros((4, 3), np.float32))

    kept = _trimmed(model, scan)

    assert len(kept) == 2
    assert np.allclose(kept.means[:, 0], [0.0, 2.0])


def test_hela_modellen_skrivs_utan_gallring(tmp_path):
    # Telefonens tak sätts under träningen, inte här: exporten som gallrade
    # efteråt mätte volym och behöll därför de rundaste, alltså de suddigaste.
    model = SplatModel(means=np.zeros((10, 3), np.float32),
                       quats=np.zeros((10, 4), np.float32),
                       scales=np.zeros((10, 3), np.float32),
                       opacities=np.zeros(10, np.float32),
                       colors=np.zeros((10, 3), np.float32))

    write_ply(model, tmp_path / "splat.ply")

    header = (tmp_path / "splat.ply").read_bytes()[:200].decode("ascii", "ignore")
    assert "element vertex 10" in header


def _read_spz(path):
    """Läser tillbaka en SPZ-fil precis som MetalSplatter gör det.

    Skrivet efter ``spz-swift`` och inte efter ``write_spz``: ett test som
    speglar skrivaren hade bara bevisat att den är konsekvent med sig själv.
    Här avkodas filen som mottagaren avkodar den, inklusive dess omräkning
    från "höger, upp, bak" till PLY-konventionen.
    """
    import gzip
    import struct

    raw = gzip.decompress(Path(path).read_bytes())
    magic, version, count, sh_degree, bits, flags, _ = struct.unpack_from("<IIIBBBB", raw)
    assert magic == 0x5053474E and version == 3 and sh_degree == 0 and flags == 0

    body = np.frombuffer(raw, np.uint8, offset=16)
    lengths = (count * 9, count, count * 3, count * 3, count * 4)
    edges = np.cumsum((0,) + lengths)
    parts = [body[start:stop] for start, stop in zip(edges, edges[1:])]

    packed = parts[0].reshape(-1, 3).astype(np.int32)
    fixed = packed[:, 0] | (packed[:, 1] << 8) | (packed[:, 2] << 16)
    fixed = np.where(fixed & 0x800000, fixed - (1 << 24), fixed)
    flip = np.array([1.0, -1.0, -1.0])
    means = fixed.reshape(-1, 3) / (1 << bits) * flip

    opacities = np.log(parts[1] / 255 / (1 - parts[1] / 255))
    colors = (parts[2].reshape(-1, 3) / 255 - 0.5) / 0.15 * SH_DC + 0.5
    scales = parts[3].reshape(-1, 3) / 16 - 10

    # "Minsta tre": de tre minsta talen bakifrån, tio bitar var, sedan säger de
    # två översta bitarna vilket tal som utelämnades och ska räknas fram.
    word = parts[4].reshape(-1, 4).astype(np.uint32)
    word = word[:, 0] | word[:, 1] << 8 | word[:, 2] << 16 | word[:, 3] << 24
    largest = (word >> np.uint32(30)).astype(np.int64)
    xyzw = np.zeros((count, 4))
    for index in (3, 2, 1, 0):
        keep = largest != index
        sign = np.where(word & np.uint32(1 << 9), -1.0, 1.0)
        xyzw[:, index] = np.where(keep, sign * (word & np.uint32(511)) * np.sqrt(0.5) / 511, 0)
        word = np.where(keep, word >> np.uint32(10), word)
    xyzw[np.arange(count), largest] = np.sqrt(
        np.maximum(0, 1 - (xyzw ** 2).sum(axis=1)))

    xyzw[:, :3] *= flip
    return means, xyzw[:, [3, 0, 1, 2]], scales, opacities, colors


def test_spz_gar_att_lasa_tillbaka(tmp_path):
    # Formatet kvantiserar hårt, så det som kontrolleras är att varje fält
    # hamnar i rätt fack och överlever tur och retur — inte att det är exakt.
    generator = np.random.default_rng(0)
    quats = generator.normal(size=(64, 4)).astype(np.float32)
    quats /= np.linalg.norm(quats, axis=1, keepdims=True)
    model = SplatModel(
        means=generator.uniform(-4, 4, (64, 3)).astype(np.float32),
        quats=quats,
        scales=generator.uniform(-6, -2, (64, 3)).astype(np.float32),
        opacities=generator.uniform(-3, 3, 64).astype(np.float32),
        colors=generator.uniform(0.05, 0.95, (64, 3)).astype(np.float32))

    write_spz(model, tmp_path / "splat.spz")
    means, read_quats, scales, opacities, colors = _read_spz(tmp_path / "splat.spz")

    # Ordningen slumpas i skrivaren, så jämförelsen sker mot samma permutation.
    order = np.random.default_rng(0).permutation(64)
    assert np.allclose(means, model.means[order], atol=3e-4)
    assert np.allclose(scales, model.scales[order], atol=0.04)
    assert np.allclose(colors, model.colors[order], atol=0.02)
    assert np.allclose(opacities, model.opacities[order], atol=0.05)
    # Kvaternionen mäts som rotation och inte komponentvis: formatet lagrar tre
    # tal och räknar fram det fjärde ur normen, så ett kvantiseringsfel på en
    # tusendel i de tre kan slå igenom tiofalt i det fjärde utan att rotationen
    # rört sig nämnvärt. Skalärprodukten är vinkeln mellan dem, och den ska vara
    # noll — tecknet spelar ingen roll, en kvaternion och dess negation är samma
    # vridning.
    turned = np.abs((read_quats * model.quats[order]).sum(axis=1))
    assert np.degrees(2 * np.arccos(turned.clip(0, 1))).max() < 1.0


def test_spz_ar_mycket_mindre_an_ply(tmp_path):
    # Tjugo byte mot sextioåtta är hela skälet till bytet: det är den kvoten
    # som gör att budgeten kan höjas utan att nedladdningen växer.
    model = SplatModel(means=np.zeros((5000, 3), np.float32),
                       quats=np.tile([1.0, 0, 0, 0], (5000, 1)).astype(np.float32),
                       scales=np.zeros((5000, 3), np.float32),
                       opacities=np.zeros(5000, np.float32),
                       colors=np.zeros((5000, 3), np.float32))

    write_ply(model, tmp_path / "splat.ply")
    write_spz(model, tmp_path / "splat.spz")

    assert (tmp_path / "splat.spz").stat().st_size < (tmp_path / "splat.ply").stat().st_size / 3


def test_okand_fargkalla_avvisas(tmp_path):
    with pytest.raises(ValueError, match="färgkälla"):
        bake_room(tmp_path, color_source="splatt")
