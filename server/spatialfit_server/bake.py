"""Färgen till atlasen: varje texel vägs ihop ur de bilder som såg den bäst.

Appens texturering låter varje triangel välja ett enda foto. Det ger full
upplösning men också en synlig skarv där två foton möts, eftersom de togs med
olika exponering. Här blandas bilderna i stället per texel, och skarven blir en
övergång i stället för ett hopp.

Vad som får vara med i blandningen avgör skärpan. Vägs bara geometrin — hur
rakt på och hur nära kameran stod — hamnar ett rörelseoskarpt foto taget rakt
på framför ett skarpt taget lite snett, och medelvärdet blir suddigt utan att
någon enskild bild är dålig. Mätt på ett riktigt rum: 3,9 foton per texel gav
kontrasten 1,95, medan samma rum målat ur enbart varje texels bästa foto gav
2,67. Skärpan fanns alltså i materialet, blandningen kastade bort den.

Två grepp hämtar hem den. Fotots egen kontrast går in i vikten, så ett suddigt
foto väger mindre överallt, och bara foton som når upp till en andel av texelns
bästa vikt får vara med. Kvar blir ungefär två bilder per texel — nog för att
mjuka upp exponeringsskarvarna, få nog för att inte smeta. Samma rum landar då
på 2,76 med oförändrad täckning.

Kraven på en bild är desamma som i ``Texturing/ViewSelection.swift`` — vänd mot
kameran, inom räckhåll och inte skymd — men de tillämpas per texel i stället för
per triangel, och de utesluter inte varandra.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .atlas import Atlas
from .bundle import Keyframe

#: Minsta ``cos(vinkel)`` mellan yta och siktlinje. 0.35 ≈ 70°.
MINIMUM_FACING = 0.35
#: Längre bort upptar ytan för få pixlar för att måla med.
MAXIMUM_DISTANCE_M = 4.5
#: Marginal i djuptestet. LiDAR brusar, och en för snäv gräns gör ytan fläckig.
OCCLUSION_TOLERANCE_M = 0.12
#: Grått för det ingen bild såg. Samma ton som den omålade mesh:en i appen.
UNSEEN_COLOR = np.array([199, 199, 199], np.float32)
#: Ett fotos vikt skalas med (dess kontrast / medianens) upphöjt till detta.
#: Kvadraten valdes för att den slår igenom på de verkligt suddiga bilderna —
#: spannet i en handhållen skanning är fyrfaldigt — utan att stänga ute dem.
SHARPNESS_POWER = 2.0
#: Ett foto måste väga minst så här stor andel av texelns bästa foto för att få
#: vara med. Lägre smetar, högre närmar sig ett foto per texel och ger sömmar.
BLEND_THRESHOLD = 0.7


@dataclass
class BakeResult:
    texture: np.ndarray  # (size, size, 3) uint8
    #: Andel texlar som minst en bild såg. Lågt tal betyder gles skanning.
    seen_fraction: float


def bake(atlas: Atlas, keyframes: list[Keyframe]) -> BakeResult:
    texel_count = len(atlas.texel_positions)
    scales = _sharpness_scales(keyframes)

    # Två svep över bilderna. Tröskeln är relativ till texelns bästa foto, och
    # det bästa är inte känt förrän alla bilder är sedda. Bidragen räknas om i
    # stället för att sparas — allt på en gång är fyrtio bilder gånger miljontals
    # texlar, och minnet är den knappare resursen av de två.
    best = np.zeros(texel_count, np.float32)
    for keyframe in keyframes:
        result = _contribution(atlas, keyframe, scales[keyframe.id])
        if result is None:
            continue
        _, weights, visible = result
        best[visible] = np.maximum(best[visible], weights)
    best *= BLEND_THRESHOLD

    total = np.zeros((texel_count, 3), np.float32)
    weight = np.zeros(texel_count, np.float32)
    for keyframe in keyframes:
        result = _contribution(atlas, keyframe, scales[keyframe.id])
        if result is None:
            continue
        samples, weights, visible = result
        keep = weights >= best[visible]
        if not keep.any():
            continue
        texels = np.flatnonzero(visible)[keep]
        kept = weights[keep]
        total[texels] += samples[keep] * kept[:, None]
        weight[texels] += kept

    seen = weight > 0
    colors = np.tile(UNSEEN_COLOR, (texel_count, 1))
    colors[seen] = total[seen] / weight[seen, None]

    texture = np.tile(UNSEEN_COLOR.astype(np.uint8), (atlas.size, atlas.size, 1))
    texture[atlas.texel_rows, atlas.texel_columns] = np.clip(colors, 0, 255).astype(np.uint8)

    # Texlar strax utanför en ö färgas som sin granne. Utan det lyser
    # bakgrunden igenom längs varje söm när texturen filtreras.
    filled = np.zeros((atlas.size, atlas.size), bool)
    filled[atlas.texel_rows, atlas.texel_columns] = True
    texture = _dilate(texture, filled, passes=4)

    fraction = float(seen.sum()) / texel_count if texel_count else 0.0
    return BakeResult(texture=texture, seen_fraction=fraction)


def _sharpness_scales(keyframes: list[Keyframe]) -> dict[int, float]:
    """Hur skarpt varje foto är, mätt mot de andra i samma skanning.

    Måttet är medelskillnaden mellan grannpixlar. Rörelseoskärpa jämnar ut den,
    och den som skannar går ju medan bilden tas. Absolutnivån säger inget — ett
    rum med vita väggar har låg kontrast överallt — så värdena normeras mot
    medianen i just den här skanningen.
    """
    contrasts = {}
    for keyframe in keyframes:
        grey = keyframe.image.astype(np.float32).mean(axis=2)
        contrasts[keyframe.id] = float(
            (np.abs(np.diff(grey, axis=0)).mean()
             + np.abs(np.diff(grey, axis=1)).mean()) / 2)

    reference = float(np.median(list(contrasts.values()))) if contrasts else 0.0
    if reference <= 0:
        return {identifier: 1.0 for identifier in contrasts}
    return {identifier: (value / reference) ** SHARPNESS_POWER
            for identifier, value in contrasts.items()}


def _contribution(atlas: Atlas, keyframe: Keyframe, sharpness: float):
    """Färgprov, vikt och mask för de texlar bilden faktiskt såg."""
    pixels, depth = keyframe.project(atlas.texel_positions)
    width, height = float(keyframe.image_size[0]), float(keyframe.image_size[1])

    visible = ((depth > 0.05) & (depth < MAXIMUM_DISTANCE_M)
               & (pixels[:, 0] >= 0) & (pixels[:, 0] < width)
               & (pixels[:, 1] >= 0) & (pixels[:, 1] < height))
    if not visible.any():
        return None

    to_camera = keyframe.position - atlas.texel_positions
    distance = np.linalg.norm(to_camera, axis=1)
    with np.errstate(divide="ignore", invalid="ignore"):
        direction = to_camera / distance[:, None]
    # Ytan kan vara vänd åt endera hållet — LiDAR-mesh har ingen pålitlig
    # utsida, så beloppet avgör.
    facing = np.abs(np.einsum("ij,ij->i", direction, atlas.texel_normals))
    visible &= facing > MINIMUM_FACING

    if keyframe.depth is not None:
        visible &= _unoccluded(keyframe, pixels, depth, visible)

    if not visible.any():
        return None

    rows = np.clip(pixels[visible, 1].astype(np.int32), 0, keyframe.image.shape[0] - 1)
    columns = np.clip(pixels[visible, 0].astype(np.int32), 0, keyframe.image.shape[1] - 1)
    samples = keyframe.image[rows, columns].astype(np.float32)

    # Rakt på och nära väger tyngst. Kvadraten gör övergången mellan två
    # bilder mjukare än en rak proportion. Skärpan skalar hela bilden lika.
    weights = sharpness * (facing[visible] ** 2) / np.maximum(distance[visible], 0.1)
    return samples, weights, visible


def _unoccluded(keyframe: Keyframe, pixels: np.ndarray, depth: np.ndarray,
                visible: np.ndarray) -> np.ndarray:
    """Låg LiDAR-djupet framför texeln stod något emellan."""
    result = np.zeros(len(depth), bool)
    if not visible.any():
        return result

    depth_height, depth_width = keyframe.depth.shape
    columns = (pixels[visible, 0] / keyframe.image_size[0] * depth_width).astype(np.int32)
    rows = (pixels[visible, 1] / keyframe.image_size[1] * depth_height).astype(np.int32)
    np.clip(columns, 0, depth_width - 1, out=columns)
    np.clip(rows, 0, depth_height - 1, out=rows)

    measured = keyframe.depth[rows, columns]
    # Ett nollvärde betyder att LiDAR inte nådde dit, inte att ytan är skymd.
    result[visible] = (measured <= 0) | (depth[visible] <= measured + OCCLUSION_TOLERANCE_M)
    return result


def _dilate(texture: np.ndarray, filled: np.ndarray, passes: int) -> np.ndarray:
    """Breder ut färgen ett steg i taget över de texlar som står tomma."""
    result = texture.astype(np.float32)
    mask = filled.copy()

    for _ in range(passes):
        neighbours = np.zeros_like(result)
        counts = np.zeros(mask.shape, np.float32)
        for shift, axis in ((1, 0), (-1, 0), (1, 1), (-1, 1)):
            neighbours += np.roll(np.where(mask[..., None], result, 0), shift, axis)
            counts += np.roll(mask.astype(np.float32), shift, axis)

        grow = (~mask) & (counts > 0)
        if not grow.any():
            break
        result[grow] = neighbours[grow] / counts[grow, None]
        mask |= grow

    return np.clip(result, 0, 255).astype(np.uint8)
