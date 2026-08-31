"""Räknar om kameraplaceringarna ur fotona i stället för att tro på telefonen.

ARKits VIO är gratis och snabb, men ``tools/pose_check.py`` mätte vad den kostar:
en ARKit-pose missar sin egen bildpunkt med 13 pixlar i median, COLMAP klarar
0,8. Felet går inte att laga senare. Två foton som säger att samma kant sitter på
olika ställen tvingar träningen att lägga en gaussare mitt emellan — det ser ut
som sudd för att det ÄR sudd, och varken hårdare klämmor eller fler gaussare
hjälper. Mätt i tre körningar av samma rum: samma inställningar men COLMAP-poser
gav en skarp bild med HALVA antalet gaussare.

Poserna landar i ARKITS värld, inte i COLMAPs egen. Skalan måste komma
någonstans ifrån: COLMAP vet hur rummet SER ut men inte hur stort det är, och
det är LiDAR som mäter meter. Umeyama-passningen ger rotation, förflyttning och
en skalfaktor som tar rekonstruktionen till metrar. Därmed behåller ``room.mesh``
och djupkartorna sin mening, och ``measured_points`` byggs om av sig själv ur de
nya poserna.

Går något fel returneras ``None`` och bakningen kör vidare på ARKits poser. Ett
suddigare rum är ett bättre svar än inget rum: SfM registrerar inga bilder alls i
ett rum med kala väggar, och pycolmap är inte installerat överallt.
"""

from __future__ import annotations

import logging
import tempfile
from dataclasses import replace
from pathlib import Path

import numpy as np

from .bundle import Keyframe, ScanBundle

log = logging.getLogger(__name__)

#: Så stor andel av fotona som måste bli lösta för att bytet ska räknas som
#: lyckat. Ett rum spricker i flera delrekonstruktioner om en vägg är för kal,
#: och bara den största används — hälften av fotona vore alltså halva rummet.
MINIMUM_REGISTERED = 0.6

#: Reprojektionsfel i pixlar som de NYA poserna får ha. Kontrollen fångar det
#: som annars inte syns förrän efter en hel träning: det finns fyra tecken att
#: slarva med mellan COLMAPs hålkamera och ARKits Y-upp, och en pose som pekar åt
#: fel håll ger fortfarande en snygg Umeyama-passning. COLMAP själv ligger under
#: en pixel, ARKit på tretton, så gränsen behöver inte vara fintrimmad.
MAXIMUM_REPROJECTION = 3.0

#: Färre foton än så är inte en rekonstruktion utan en gissning.
MINIMUM_KEYFRAMES = 20


def umeyama(source: np.ndarray, target: np.ndarray):
    """Likformig passning source → target: rotation, skala, förflyttning.

    Skalan måste vara med. COLMAP vet inte hur stort rummet är — bara hur det
    ser ut — så en rekonstruktion som är perfekt men halva storleken skulle
    annars mäta som helt fel.
    """
    source_mean, target_mean = source.mean(0), target.mean(0)
    a, b = source - source_mean, target - target_mean
    u, singular, vt = np.linalg.svd(a.T @ b / len(a))
    correction = np.eye(3)
    # Speglingen måste stängas ute: en spegelvänd lösning kan passa punkterna
    # lika bra i minsta kvadrat men är inte en stelkroppsrörelse.
    correction[2, 2] = np.sign(np.linalg.det(u @ vt))
    rotation = (u @ correction @ vt).T
    scale = float(singular @ np.diag(correction) / a.var(0).sum())
    return rotation, scale, target_mean - scale * rotation @ source_mean


def refined(bundle: ScanBundle, directory: Path,
            workspace: Path | None = None) -> ScanBundle | None:
    """Skanningen med COLMAPs poser, eller ``None`` om de inte går att lita på.

    ``directory`` är skanningsmappen — COLMAP läser fotona därifrån, samma filer
    som ``ScanBundle.load`` redan öppnat.
    """
    if len(bundle.keyframes) < MINIMUM_KEYFRAMES:
        log.info("hoppar över SfM: bara %d foton", len(bundle.keyframes))
        return None

    try:
        import pycolmap
    except ImportError:
        log.warning("pycolmap saknas — bakar på ARKits poser")
        return None

    if workspace is None:
        with tempfile.TemporaryDirectory(prefix="sfm-") as temporary:
            return refined(bundle, directory, Path(temporary))

    frames = {f"kf{frame.id}.jpg": frame for frame in bundle.keyframes}
    workspace.mkdir(parents=True, exist_ok=True)
    database = workspace / "colmap.db"

    try:
        # Ett enda kameraobjekt för alla foton: det är samma lins hela vägen, och
        # delad kalibrering är både snabbare och stabilare än hundratals gissningar.
        pycolmap.extract_features(database, directory,
                                  image_names=sorted(frames),
                                  camera_mode=pycolmap.CameraMode.SINGLE)
        # Sekventiell matchning — fotona är tagna längs en väg, så grannar i tid
        # är grannar i rummet. Loop-stängningen håller ihop varvet.
        pycolmap.match_sequential(database)
        reconstructions = pycolmap.incremental_mapping(database, directory, workspace)
    except Exception as error:  # pycolmap kastar egna, odokumenterade fel
        log.warning("SfM misslyckades (%s) — bakar på ARKits poser", error)
        return None

    if not reconstructions:
        log.warning("COLMAP registrerade inga bilder — rummet är för slätt för SfM")
        return None

    # Största delen räknas. Ett rum kan spricka i flera om en vägg är kal.
    best = max(reconstructions.values(), key=lambda part: part.num_reg_images())
    solved = [image for image in best.images.values() if image.name in frames]
    if len(solved) < MINIMUM_REGISTERED * len(frames):
        log.warning("bara %d av %d foton lösta — bakar på ARKits poser",
                    len(solved), len(frames))
        return None

    rotation, scale, offset = umeyama(
        np.asarray([image.projection_center() for image in solved]),
        np.asarray([frames[image.name].position for image in solved]))

    posed = [(image, _keyframe(frames[image.name], image, best, rotation, scale, offset))
             for image in solved]
    # COLMAP räknar upp bilderna i sin egen ordning, och nedströms plockas var
    # tionde keyframe. En omkastad lista jämför alltså andra foton än originalet.
    posed.sort(key=lambda pair: pair[1].id)

    miss = _reprojection(posed, best, rotation, scale, offset)
    if miss is None:
        log.warning("inga gemensamma punkter att kontrollera mot — ARKits poser")
        return None
    if miss > MAXIMUM_REPROJECTION:
        log.warning("de nya poserna missar med %.1f px — något pekar åt fel håll, "
                    "bakar på ARKits poser", miss)
        return None

    log.info("COLMAP löste %d av %d foton, skala %.4f, reprojektionsfel %.2f px",
             len(solved), len(frames), scale, miss)
    return ScanBundle(mesh=bundle.mesh, keyframes=[frame for _, frame in posed])


def _keyframe(frame: Keyframe, image, reconstruction,
              rotation: np.ndarray, scale: float, offset: np.ndarray) -> Keyframe:
    """Samma foto men med COLMAPs placering, uttryckt i ARKits värld."""
    pose = image.cam_from_world()
    # x_kamera(m) = R_c·R^T·x_värld + (s·t_c − R_c·R^T·t). Skalan hör hemma i
    # förflyttningen, aldrig i rotationen — en skalad rotation är ingen pose.
    turn = pose.rotation.matrix() @ rotation.T
    move = scale * pose.translation - turn @ offset

    # Hålkamera → ARKits kamerarum. ARKit har Y uppåt och Z bakåt, COLMAP
    # tvärtom, och matrisen är sin egen invers.
    flip = np.diag([1.0, -1.0, -1.0])
    camera_from_world = np.eye(4, dtype=np.float32)
    camera_from_world[:3, :3] = flip @ turn
    camera_from_world[:3, 3] = flip @ move

    # COLMAP löste poserna med SIN kalibrering; att blanda in ARKits skulle göra
    # dem inbördes oense igen.
    lens = reconstruction.cameras[image.camera_id]
    intrinsics = np.array([[lens.focal_length_x, 0.0, lens.principal_point_x],
                           [0.0, lens.focal_length_y, lens.principal_point_y],
                           [0.0, 0.0, 1.0]], np.float32)

    return replace(frame, camera_from_world=camera_from_world, intrinsics=intrinsics)


def _reprojection(posed, reconstruction,
                  rotation: np.ndarray, scale: float, offset: np.ndarray) -> float | None:
    """Medianfelet när COLMAPs punktmoln kastas tillbaka genom de nya poserna."""
    cloud = {number: point.xyz for number, point in reconstruction.points3D.items()}
    misses = []
    for image, frame in posed:
        seen = [(point.xy, cloud[point.point3D_id])
                for point in image.points2D if point.has_point3D()]
        if not seen:
            continue
        world = np.asarray([xyz for _, xyz in seen], np.float32)
        pixels, _ = frame.project(scale * world @ rotation.T + offset)
        misses.append(np.linalg.norm(
            pixels - np.asarray([xy for xy, _ in seen], np.float32), axis=1))

    return float(np.median(np.concatenate(misses))) if misses else None
