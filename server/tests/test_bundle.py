"""Vad i skanningen som får lov att bestämma.

Två städningar med samma form: mät något om varje mätning och låt de dåliga
väga lätt. Punkterna rensas på om fotona ser RAKT IGENOM dem — LiDAR ser genom
fönster och i speglingar, och de punkterna ger flygarna en laglig plats mitt i
rummet. Fotona viktas på skärpa — ett foto taget mitt i en sväng bär sann
geometri men osann detalj.

I båda fallen är den enkla utvägen fel: avstånd till meshen skulle kasta
gardiner, och att gallra suddiga foton skulle kasta hela vyer.
"""

from __future__ import annotations

import numpy as np
import pytest

from spatialfit_server.bundle import (BLUR_WEIGHT_FLOOR, Keyframe, agreement, blur,
                                      measured_points, sharpness_weights)


def _keyframe(identifier: int, position, depth: np.ndarray) -> Keyframe:
    """En kamera i ``position`` som tittar längs −z, med given djupkarta."""
    camera_from_world = np.eye(4, dtype=np.float32)
    camera_from_world[:3, 3] = -np.asarray(position, np.float32)

    # Brännvidd lika med halva bilden ⇒ 90° synfält, ungefär som telefonens.
    # Med en trång lins hamnar grannkameran utanför bild och kan inte motsäga
    # något, vilket gör hela provet meningslöst.
    size = np.array([depth.shape[1], depth.shape[0]], np.float32)
    intrinsics = np.array([[size[0] / 2, 0, size[0] / 2],
                           [0, size[1] / 2, size[1] / 2],
                           [0, 0, 1]], np.float32)

    return Keyframe(id=identifier,
                    camera_from_world=camera_from_world,
                    intrinsics=intrinsics,
                    image_size=size,
                    depth_size=size.astype(np.int32),
                    image=np.zeros((depth.shape[0], depth.shape[1], 3), np.uint8),
                    depth=depth)


def _wall_at(distance: float, size: int = 32) -> np.ndarray:
    return np.full((size, size), distance, np.float32)


def test_en_punkt_pa_ytan_far_medhall():
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0))]

    assert agreement(np.array([[0.0, 0.0, -3.0]], np.float32), frames)[0] == 1.0


def test_en_punkt_som_fotot_ser_igenom_faller():
    """Väggen ligger tre meter bort; en punkt en meter bort kan inte finnas."""
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0))]

    assert agreement(np.array([[0.0, 0.0, -1.0]], np.float32), frames)[0] == 0.0


def test_en_punkt_bakom_vaggen_ger_ingen_asikt():
    """Skymd av väggen — fotot vet ingenting, och tystnad är inget bevis."""
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0))]

    assert agreement(np.array([[0.0, 0.0, -5.0]], np.float32), frames)[0] == 1.0


def test_en_punkt_utanfor_bildrutan_ger_ingen_asikt():
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0))]

    assert agreement(np.array([[9.0, 0.0, -3.0]], np.float32), frames)[0] == 1.0


def test_enigheten_vags_over_alla_foton():
    """Ett foto ser ytan, tre ser igenom: en fjärdedels medhåll."""
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0))]
    frames += [_keyframe(number, [0, 0, 0], _wall_at(9.0)) for number in (1, 2, 3)]

    found = agreement(np.array([[0.0, 0.0, -3.0]], np.float32), frames)

    assert found[0] == 0.25


def test_luftpunkten_rensas_men_ytan_blir_kvar():
    """Hela vägen: djupkartan bygger molnet och dömer det sedan.

    Kameran flyttas mellan bilderna, annars projiceras varje punkt på samma
    djuppixel den kom ifrån och kan aldrig motsägas.
    """
    # Fem kameror: den falska punkten får ett vittne — fotot den kom ur — mot
    # fyra motsägelser, alltså 0,2 och under gränsen.
    frames = [_keyframe(number, [0.15 * number, 0, 0], _wall_at(3.0))
              for number in range(5)]
    # En enda falsk mätning mitt i luften, som en spegling ger.
    frames[0].depth[16, 16] = 1.0

    points = measured_points(frames, voxel=0.02)

    assert len(points) > 100
    # Väggen ligger tre meter rakt fram; inget ska ha blivit kvar närmare.
    assert points[:, 2].max() < -2.5


def test_rensningen_gar_att_stanga_av():
    """Samma uppställning som ovan — här ska luftpunkten få vara kvar."""
    frames = [_keyframe(number, [0.15 * number, 0, 0], _wall_at(3.0))
              for number in range(5)]
    frames[0].depth[16, 16] = 1.0

    kept = measured_points(frames, voxel=0.02, minimum_agreement=0.0)

    assert kept[:, 2].max() > -1.5


def _texture(rng, blocks: int = 16, side: int = 10) -> np.ndarray:
    """Plana fält med skarpa kanter — väggar, tavlor och karmar.

    Vitt brus duger INTE som skarp bild: smetas det ut lägger uint8-avrundningen
    tillbaka en darrning i varje pixel som måttet läser som skärpa, och talet
    mättar kring 0,32 hur hårt man än smetar. Ett rum är plana ytor med kanter
    emellan, och där går måttet hela vägen upp.
    """
    flat = np.kron(rng.integers(0, 256, (blocks, blocks)), np.ones((side, side)))
    return np.repeat(flat.astype(np.uint8)[:, :, None], 3, axis=2)


def _smeared(image: np.ndarray, length: int) -> np.ndarray:
    """Samma foto draget i sidled, som när kameran svänger under slutaren."""
    from scipy.ndimage import uniform_filter1d

    return uniform_filter1d(image, length, axis=1).astype(np.uint8)


def test_oskarpa_stiger_nar_bilden_smetas():
    rng = np.random.default_rng(0)
    sharp = _texture(rng)

    values = [blur(sharp.mean(axis=2) / 255.0),
              blur(_smeared(sharp, 3).mean(axis=2) / 255.0),
              blur(_smeared(sharp, 9).mean(axis=2) / 255.0)]

    assert values[0] < values[1] < values[2]


def test_rorelseoskarpa_at_ett_hall_avslojas():
    """Värsta ledet bestämmer — annars döljs sidledssuddet av lodrät skärpa."""
    rng = np.random.default_rng(1)
    smeared = _smeared(_texture(rng), 9)

    # Lodrätt är bilden orörd, i sidled helt utsmetad.
    assert blur(smeared.mean(axis=2) / 255.0) > 0.5


def test_det_suddiga_fotot_vager_lattare_an_det_skarpa():
    rng = np.random.default_rng(2)
    sharp = _texture(rng)
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0)),
              _keyframe(1, [0, 0, 0], _wall_at(3.0))]
    frames[0].image = sharp
    frames[1].image = _smeared(sharp, 5)

    weights = sharpness_weights(frames)

    assert weights[0] > weights[1]


def test_vikterna_har_medelvardet_ett():
    """Annars är ändringen också en sänkt inlärningstakt — två i en."""
    rng = np.random.default_rng(3)
    frames = []
    for number, length in enumerate((1, 3, 5, 9)):
        frame = _keyframe(number, [0, 0, 0], _wall_at(3.0))
        frame.image = _smeared(_texture(rng), length)
        frames.append(frame)

    weights = sharpness_weights(frames)

    assert weights.mean() == pytest.approx(1.0)
    # Golvet är relativt, så det minsta förhållandet mellan två foton är känt.
    assert weights.min() / weights.max() >= BLUR_WEIGHT_FLOOR - 1e-9


def test_aven_det_suddigaste_fotot_far_vara_med():
    """Noll vore gallring, och gallring knäcker geometrin — skurarna är vyer."""
    rng = np.random.default_rng(4)
    frames = [_keyframe(0, [0, 0, 0], _wall_at(3.0)),
              _keyframe(1, [0, 0, 0], _wall_at(3.0))]
    frames[0].image = _texture(rng)
    frames[1].image = np.zeros_like(frames[0].image)  # helt strukturlöst

    assert sharpness_weights(frames).min() > 0
