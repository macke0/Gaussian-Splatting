"""Bakningen testas mot en syntetisk vägg, inte mot en riktig skanning.

Poängen är att kunna svara på "hamnade färgen på rätt ställe i rummet" utan att
någon behöver skanna om. En kamera med känd placering som tittar rakt på en
enfärgad vägg ska ge en atlas i exakt den färgen.
"""

from __future__ import annotations

import json

import numpy as np
import pytest
from PIL import Image

from spatialfit_server import atlas as atlas_module
from spatialfit_server.bake import UNSEEN_COLOR, _exposures, bake
from spatialfit_server.bundle import Keyframe, ScanBundle
from spatialfit_server.mesh import FormatError, SceneMesh, TexturedMesh


def wall() -> tuple[np.ndarray, np.ndarray]:
    """En 2×2 m vägg i planet z = 0, med normalen mot +z."""
    positions = np.array([[-1, -1, 0], [1, -1, 0], [1, 1, 0], [-1, 1, 0]], np.float32)
    faces = np.array([[0, 1, 2], [0, 2, 3]], np.uint32)
    return positions, faces


def camera_looking_at_wall(color: tuple[int, int, int], distance: float = 2.0,
                           identifier: int = 0) -> Keyframe:
    """Kamera i +z som tittar mot origo, med en enfärgad bild."""
    world_from_camera = np.eye(4, dtype=np.float32)
    world_from_camera[2, 3] = distance

    size = 256
    focal = 200.0
    intrinsics = np.array([[focal, 0, size / 2],
                           [0, focal, size / 2],
                           [0, 0, 1]], np.float32)

    image = np.tile(np.array(color, np.uint8), (size, size, 1))
    return Keyframe(id=identifier,
                    camera_from_world=np.linalg.inv(world_from_camera),
                    intrinsics=intrinsics,
                    image_size=np.array([size, size], np.float32),
                    depth_size=np.array([0, 0], np.int32),
                    image=image,
                    depth=None)


def textured_image(size: int = 256) -> np.ndarray:
    """En bild med mönster. En enfärgad duger inte att jämka exponering mot —
    utan variation går det inte att skilja förstärkning från nivå."""
    ramp = np.linspace(30, 220, size, dtype=np.float32)
    field = ramp[None, :] + ramp[:, None] / 2
    return np.repeat(np.clip(field, 0, 255)[:, :, None], 3, axis=2).astype(np.uint8)


def unwrapped_wall(size: int = 64) -> atlas_module.Atlas:
    positions, faces = wall()
    normals = atlas_module.vertex_normals(positions, faces)
    # Utvecklingen hoppas över: väggen ligger redan i ett plan, och en fast UV
    # gör testet oberoende av vad xatlas råkar välja.
    uvs = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)
    return atlas_module.rasterize(positions, normals, uvs, faces, size)


class TestRasterisering:

    def test_texlar_far_varldspunkter_inom_vaggen(self):
        atlas = unwrapped_wall()
        assert len(atlas.texel_positions) > 0
        assert np.all(np.abs(atlas.texel_positions[:, :2]) <= 1.001)
        assert np.allclose(atlas.texel_positions[:, 2], 0, atol=1e-4)

    def test_hela_atlasen_tacks_av_en_kvadratisk_vagg(self):
        atlas = unwrapped_wall()
        assert atlas.coverage > 0.95

    def test_normalen_pekar_ut_ur_vaggen(self):
        atlas = unwrapped_wall()
        assert np.allclose(np.abs(atlas.texel_normals[:, 2]), 1, atol=1e-4)


class TestBakning:

    def test_en_enfargad_vagg_ger_en_enfargad_atlas(self):
        atlas = unwrapped_wall()
        result = bake(atlas, [camera_looking_at_wall((200, 60, 40))])

        assert result.seen_fraction > 0.99
        painted = result.texture[atlas.texel_rows, atlas.texel_columns]
        assert np.allclose(painted, [200, 60, 40], atol=2)

    def test_tva_bilder_blandas_i_stallet_for_att_valja_en(self):
        atlas = unwrapped_wall()
        result = bake(atlas, [camera_looking_at_wall((255, 0, 0), identifier=0),
                              camera_looking_at_wall((0, 0, 255), identifier=1)])

        painted = result.texture[atlas.texel_rows, atlas.texel_columns]
        # Lika bra vyer, lika vikt: mitt emellan, inte den enas färg.
        assert np.allclose(painted[:, 0], 127, atol=3)
        assert np.allclose(painted[:, 2], 127, atol=3)

    def test_en_yta_bortom_rackhall_lamnas_omalad(self):
        atlas = unwrapped_wall()
        result = bake(atlas, [camera_looking_at_wall((200, 60, 40), distance=9.0)])

        assert result.seen_fraction == 0
        painted = result.texture[atlas.texel_rows, atlas.texel_columns]
        assert np.allclose(painted, UNSEEN_COLOR, atol=1)

    def test_enstaka_omalade_texlar_fylls_av_sina_grannar(self):
        """LiDAR:ns brus får enstaka texlar att falla på djuptestet mitt i en
        väl fotograferad yta. Lämnas de omålade blir ytan prickig, vilket i 3D
        ser ut som slumpade färger snarare än som hål."""
        atlas = unwrapped_wall()
        keyframe = camera_looking_at_wall((200, 60, 40))
        # Ett hål mitt i bilden: djupet påstår att något står halvvägs fram.
        keyframe.depth = np.full((64, 64), 9.0, np.float32)
        keyframe.depth[30:33, 30:33] = 1.0
        keyframe.depth_size = np.array([64, 64], np.int32)

        result = bake(atlas, [keyframe])
        assert result.seen_fraction < 1.0

        painted = result.texture[atlas.texel_rows, atlas.texel_columns]
        assert np.allclose(painted, [200, 60, 40], atol=6)

    def test_utan_bilder_blir_rummet_grat_men_inte_trasigt(self):
        atlas = unwrapped_wall()
        result = bake(atlas, [])

        assert result.seen_fraction == 0
        assert result.texture.shape == (atlas.size, atlas.size, 3)

    def test_ett_morkare_foto_jamkas_mot_de_andra(self):
        """Kameran reglerar exponering medan man går. Två bilder på samma vägg
        kan vara överens om mönstret men inte om nivån, och då fläckar
        blandningen. Här är den ena bilden halva ljusstyrkan; jämkningen ska
        hitta faktorn två mellan dem."""
        atlas = unwrapped_wall()
        bright = camera_looking_at_wall((0, 0, 0), identifier=0)
        bright.image = textured_image()
        dark = camera_looking_at_wall((0, 0, 0), identifier=1)
        dark.image = (textured_image() * 0.5).astype(np.uint8)

        exposures = _exposures(atlas, [bright, dark],
                               {0: 1.0, 1: 1.0})
        ratio = exposures[1][0].mean() / exposures[0][0].mean()
        assert ratio == pytest.approx(2.0, rel=0.1)

    def test_jamkningen_gor_inte_rummet_morkare(self):
        """En gemensam nedskalning får fotona att avvika mindre från varandra
        utan att göra dem mer överens. Anpassningen ska inte få välja den vägen."""
        atlas = unwrapped_wall()
        keyframes = []
        for identifier, factor in enumerate([1.0, 0.6, 0.8]):
            keyframe = camera_looking_at_wall((0, 0, 0), identifier=identifier)
            keyframe.image = (textured_image() * factor).astype(np.uint8)
            keyframes.append(keyframe)

        exposures = _exposures(atlas, keyframes, {0: 1.0, 1: 1.0, 2: 1.0})
        average = np.mean([gain for gain, _ in exposures.values()])
        assert average == pytest.approx(1.0, rel=0.01)

    def test_djupkartan_stoppar_farg_pa_nagot_som_lag_bakom(self):
        atlas = unwrapped_wall()
        keyframe = camera_looking_at_wall((200, 60, 40))
        # LiDAR säger att något står en halvmeter framför väggen.
        keyframe.depth = np.full((32, 32), 1.5, np.float32)
        keyframe.depth_size = np.array([32, 32], np.int32)

        result = bake(atlas, [keyframe])
        assert result.seen_fraction == 0


class TestFormat:

    def test_bakad_mesh_tar_sig_till_bytes_och_tillbaka(self):
        positions, faces = wall()
        normals = atlas_module.vertex_normals(positions, faces)
        uvs = np.array([[0, 0], [1, 0], [1, 1], [0, 1]], np.float32)

        original = TexturedMesh(positions, normals, uvs, faces)
        decoded = TexturedMesh.decode(original.encode())

        assert np.allclose(decoded.positions, positions)
        assert np.allclose(decoded.uvs, uvs)
        assert np.array_equal(decoded.indices, faces)

    def test_varje_horn_tar_32_byte(self):
        positions, faces = wall()
        normals = atlas_module.vertex_normals(positions, faces)
        uvs = np.zeros((4, 2), np.float32)

        encoded = TexturedMesh(positions, normals, uvs, faces).encode()
        assert len(encoded) == 16 + 4 * 32 + 6 * 4

    def test_en_scenmesh_ar_inte_en_bakad_mesh(self):
        with pytest.raises(FormatError):
            TexturedMesh.decode(b"SFMESH01" + bytes(8))

    def test_avhuggen_scenmesh_avvisas(self):
        with pytest.raises(FormatError):
            SceneMesh.decode(b"SFMESH01" + np.array([4, 6], "<u4").tobytes())


class TestBundle:
    """Swift kodar matriserna kolumnvis. Går det fel hamnar rummet spegelvänt."""

    def test_kolumnvis_json_blir_ratt_kameraplats(self, tmp_path):
        mesh = b"SFMESH01" + np.array([0, 0], "<u4").tobytes()
        (tmp_path / "room.mesh").write_bytes(mesh)

        world_from_camera = np.eye(4, dtype=np.float32)
        world_from_camera[:3, 3] = [1, 2, 3]
        camera_from_world = np.linalg.inv(world_from_camera)

        entry = {
            "id": 0,
            "depthSize": [0, 0],
            "imageSize": [8, 8],
            "cameraFromWorldColumns": camera_from_world.T.tolist(),
            "intrinsicsColumns": np.eye(3, dtype=np.float32).T.tolist(),
        }
        (tmp_path / "keyframes.json").write_text(json.dumps([entry]))
        Image.fromarray(np.zeros((8, 8, 3), np.uint8)).save(tmp_path / "kf0.jpg")

        bundle = ScanBundle.load(tmp_path)
        assert np.allclose(bundle.keyframes[0].position, [1, 2, 3], atol=1e-5)
