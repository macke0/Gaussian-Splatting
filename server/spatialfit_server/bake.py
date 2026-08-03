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

Skärpa räcker dock inte. Mätt på samma rum är två foton som ser samma texel oense
om 20,5 grånivåer, och hälften av det är att kameran reglerar exponering och
vitbalans medan man går: den ljusaste bilden är 1,9 gånger ljusare än den
mörkaste. Att blanda dem rakt av ger fläckar som ingen viktning kan väga bort,
för bilderna är inte oense om mönstret utan om nivån. Därför jämkas fotona mot
varandra först — se ``_exposures`` — vilket tar oenigheten till 10,2. Resten är
geometri: ytan ligger inte exakt där fotot togs.

Kraven på en bild är desamma som i ``Texturing/ViewSelection.swift`` — vänd mot
kameran, inom räckhåll och inte skymd — men de tillämpas per texel i stället för
per triangel, och de utesluter inte varandra.
"""

from __future__ import annotations

from dataclasses import dataclass, replace

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
#: Så många gånger jämkas fotonas exponering mot varandra. Anpassningen är i
#: stort sett klar efter två svep; fler börjar jaga geometrifel i stället.
EXPOSURE_SWEEPS = 3
#: Var så här många:te texel provas när exponeringen mäts. Exponering gäller
#: hela bilden, så ett stickprov räcker — och då ryms alla foton i minnet
#: samtidigt, vilket hela anpassningen bygger på.
EXPOSURE_STRIDE = 8
#: Färre delade texlar än så och ett foto står för glest för att gå att jämka.
EXPOSURE_MINIMUM_SAMPLES = 500


@dataclass
class BakeResult:
    texture: np.ndarray  # (size, size, 3) uint8
    #: Andel texlar som minst en bild såg. Lågt tal betyder gles skanning.
    seen_fraction: float


def bake(atlas: Atlas, keyframes: list[Keyframe]) -> BakeResult:
    texel_count = len(atlas.texel_positions)
    scales = _sharpness_scales(keyframes)
    exposures = _exposures(atlas, keyframes, scales)

    # Två svep över bilderna. Tröskeln är relativ till texelns bästa foto, och
    # det bästa är inte känt förrän alla bilder är sedda. Bidragen räknas om i
    # stället för att sparas — allt på en gång är fyrtio bilder gånger miljontals
    # texlar, och minnet är den knappare resursen av de två.
    best = np.zeros(texel_count, np.float32)
    for keyframe in keyframes:
        result = _contribution(atlas, keyframe, scales[keyframe.id],
                               exposures.get(keyframe.id))
        if result is None:
            continue
        _, weights, visible = result
        best[visible] = np.maximum(best[visible], weights)
    best *= BLEND_THRESHOLD

    total = np.zeros((texel_count, 3), np.float32)
    weight = np.zeros(texel_count, np.float32)
    for keyframe in keyframes:
        result = _contribution(atlas, keyframe, scales[keyframe.id],
                               exposures.get(keyframe.id))
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
    #
    # Bara de texlar som FICK färg räknas som fyllda. Räknas alla med — även de
    # ingen bild såg — hoppar utfyllnaden över dem, och LiDAR:ns brus i
    # djuptestet lämnar då enstaka omålade texlar utspridda mitt i en väl
    # fotograferad yta. På ett riktigt rum blev det ett synligt prickmönster
    # över hela golvet, vilket i 3D ser ut som slumpade färger snarare än hål.
    filled = np.zeros((atlas.size, atlas.size), bool)
    filled[atlas.texel_rows[seen], atlas.texel_columns[seen]] = True
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


def _exposures(atlas: Atlas, keyframes: list[Keyframe],
               scales: dict[int, float]) -> dict[int, tuple[np.ndarray, np.ndarray]]:
    """Jämkar fotonas exponering och vitbalans mot varandra.

    Varje foto får en förstärkning och en nivå per färgkanal, anpassade så att
    bilden stämmer med snittet av de andra på de texlar de delar. Snittet ändras
    när fotona ändras, så anpassningen upprepas några gånger.

    Att bara anpassa vore inte nog: en gemensam nedskalning av alla foton får
    dem att avvika mindre från varandra utan att göra dem mer överens, och en
    fri anpassning väljer just den genvägen — den landade på 0,4, alltså ett rum
    två och en halv gång för mörkt. Därför normeras korrigeringarna efter varje
    svep så att den genomsnittliga är "ingen ändring". Kvar blir bara
    skillnaderna mellan bilder, vilket är det som ska bort.
    """
    thin = replace(atlas,
                   texel_positions=atlas.texel_positions[::EXPOSURE_STRIDE],
                   texel_normals=atlas.texel_normals[::EXPOSURE_STRIDE],
                   texel_rows=atlas.texel_rows[::EXPOSURE_STRIDE],
                   texel_columns=atlas.texel_columns[::EXPOSURE_STRIDE])
    count = len(thin.texel_positions)

    samples: dict[int, tuple[np.ndarray, np.ndarray]] = {}
    for keyframe in keyframes:
        result = _contribution(thin, keyframe, scales[keyframe.id])
        if result is not None:
            colors, _, visible = result
            samples[keyframe.id] = (np.flatnonzero(visible), colors)
    if len(samples) < 2:
        return {}

    exposures = {identifier: (np.ones(3, np.float32), np.zeros(3, np.float32))
                 for identifier in samples}

    for _ in range(EXPOSURE_SWEEPS):
        total = np.zeros((count, 3), np.float64)
        seen = np.zeros(count, np.int32)
        for identifier, (texels, colors) in samples.items():
            gain, bias = exposures[identifier]
            total[texels] += colors * gain + bias
            seen[texels] += 1

        shared = seen >= 2
        if not shared.any():
            return {}
        reference = np.zeros((count, 3), np.float64)
        reference[shared] = total[shared] / seen[shared, None]

        for identifier, (texels, colors) in samples.items():
            usable = shared[texels]
            if usable.sum() < EXPOSURE_MINIMUM_SAMPLES:
                continue
            source = colors[usable]
            target = reference[texels[usable]]
            gain, bias = exposures[identifier]
            for channel in range(3):
                fit = np.stack([source[:, channel],
                                np.ones(len(source), np.float32)], axis=1)
                solution, *_ = np.linalg.lstsq(fit, target[:, channel], rcond=None)
                gain[channel], bias[channel] = solution

        average = np.mean([gain for gain, _ in exposures.values()], axis=0)
        offset = np.mean([bias for _, bias in exposures.values()], axis=0)
        if (average <= 0).any():
            return {}
        for gain, bias in exposures.values():
            gain /= average
            bias[:] = (bias - offset) / average

    return exposures


def _contribution(atlas: Atlas, keyframe: Keyframe, sharpness: float,
                  exposure: tuple[np.ndarray, np.ndarray] | None = None):
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
    if exposure is not None:
        gain, bias = exposure
        samples = np.clip(samples * gain + bias, 0, 255)

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
