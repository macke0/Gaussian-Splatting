"""Gaussian splatting som färgkälla, tränad på rummets egna foton.

Fogen mot resten av bakningen är ``Keyframe``, inte ``bake._contribution``.
En tränad splat renderar *nya* foton med kända poser, och de går rakt in i
``bake()`` utan att en rad där behöver ändras. Det ger tre saker som den råa
blandningen inte kan ge:

* hål fylls, eftersom en virtuell kamera kan ställas där ingen råkade fota,
* bruset jämnas ut, eftersom varje splat sett rummet från många håll,
* exponeringshoppen försvinner, eftersom en och samma modell renderar allt.

Två val skiljer den här träningen från 3DGS som det brukar se ut:

**Ingen sfärisk harmonik.** Färgen är vy-oberoende (SH-grad 0). En diffus
texturatlas kan ändå inte bära vy-beroende ljus, och med högre grad hade en
spegling från ett enda håll bakats in i väggen som en fläck.

**Ingen förtätning.** Vanlig 3DGS börjar med glesa SfM-punkter och måste klona
sig fram till täckning. Vi börjar i LiDAR-ytans hörn — geometrin är redan känd
och tät, vilket är hela poängen med att ha skannat rummet.

Poserna är låsta. De kommer från ARKit och är samma poser som måtten vilar på;
låter man dem glida får man en vackrare rendering av fel rum.

**Djupet kommer inte från splatten.** Det låg nära till hands att låta gsplat
rendera djup och skicka med det till skymningstestet, men splattens djup är ett
genomsnitt över halvgenomskinliga gaussare och blir systematiskt grundare än
ytan — desto mer ju längre träningen får hålla på. Ett skymningstest mot det
måttet kastar bort korrekta texlar i stället för skymda. En vy som står i ett
fotos pose ärver därför fotots LiDAR-djup; en inskjuten vy får inget alls.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np

from .bundle import Keyframe, ScanBundle

log = logging.getLogger(__name__)

#: Antal gaussare att starta med. Fler ger skarpare bild men långsammare steg.
DEFAULT_MAX_SPLATS = 300_000
DEFAULT_ITERATIONS = 3_000
#: Hur många extra vyer som vävs in mellan de riktiga fotona.
DEFAULT_EXTRA_VIEWS = 2

#: ARKit har Y uppåt och Z bakåt, gsplat vill ha Y nedåt och Z framåt.
#: Samma teckenbyte som ``Keyframe.project`` gör inför ``intrinsics``.
_ARKIT_TO_OPENCV = np.diag([1.0, -1.0, -1.0, 1.0]).astype(np.float32)


@dataclass
class SplatModel:
    """Tränade gaussare i världskoordinater, meter."""

    means: np.ndarray  # (n, 3)
    quats: np.ndarray  # (n, 4), wxyz
    scales: np.ndarray  # (n, 3), log-skala
    opacities: np.ndarray  # (n,), logit
    colors: np.ndarray  # (n, 3), 0–1

    def __len__(self) -> int:
        return len(self.means)


def train(bundle: ScanBundle,
          iterations: int = DEFAULT_ITERATIONS,
          max_splats: int = DEFAULT_MAX_SPLATS) -> SplatModel:
    """Passar gaussare mot fotona. Kräver CUDA."""
    import torch

    device = _device()
    frames = [frame for frame in bundle.keyframes if frame.image.size]
    if not frames:
        raise ValueError("skanningen innehåller inga foton att träna på")

    means, scales = _seed(bundle, max_splats)
    log.info("startar från %d punkter på LiDAR-ytan", len(means))

    parameters = {
        "means": torch.tensor(means, device=device),
        "scales": torch.tensor(np.log(scales), device=device),
        "quats": torch.tensor(
            np.tile([1.0, 0.0, 0.0, 0.0], (len(means), 1)).astype(np.float32), device=device),
        "opacities": torch.full((len(means),), 2.0, device=device),
        # Grått är en ärligare gissning än svart: förlusten drar det åt rätt
        # håll oavsett rummets ton.
        "colors": torch.full((len(means), 3), 0.5, device=device),
    }
    for tensor in parameters.values():
        tensor.requires_grad_(True)

    # Punkterna ligger redan rätt. Att låta dem vandra fritt vore att kasta bort
    # den mätta geometrin, så de får bara justera sig långsamt.
    optimizer = torch.optim.Adam([
        {"params": [parameters["means"]], "lr": 1e-4},
        {"params": [parameters["scales"]], "lr": 5e-3},
        {"params": [parameters["quats"]], "lr": 1e-3},
        {"params": [parameters["opacities"]], "lr": 5e-2},
        {"params": [parameters["colors"]], "lr": 2.5e-2},
    ])

    views = [_view(frame, device) for frame in frames]
    generator = np.random.default_rng(0)

    for step in range(iterations):
        view = views[generator.integers(len(views))]
        rendered = _rasterize(parameters, view, device)

        loss = (rendered - view["image"]).abs().mean()
        optimizer.zero_grad(set_to_none=True)
        loss.backward()
        optimizer.step()

        with torch.no_grad():
            parameters["colors"].clamp_(0.0, 1.0)

        if step % 500 == 0:
            log.info("steg %d/%d, förlust %.4f", step, iterations, float(loss.detach()))

    return SplatModel(
        means=parameters["means"].detach().cpu().numpy(),
        quats=parameters["quats"].detach().cpu().numpy(),
        scales=parameters["scales"].detach().cpu().numpy(),
        opacities=parameters["opacities"].detach().cpu().numpy(),
        colors=parameters["colors"].detach().cpu().numpy(),
    )


def synthetic_keyframes(model: SplatModel,
                        bundle: ScanBundle,
                        extra_views: int = DEFAULT_EXTRA_VIEWS) -> list[Keyframe]:
    """Renderar om rummet från de riktiga poserna plus några däremellan.

    De inskjutna vyerna är hela vinsten med att gå via en splat: de ser ytor
    som råkade hamna mellan två foton.
    """
    import torch

    device = _device()
    parameters = {
        "means": torch.tensor(model.means, device=device),
        "scales": torch.tensor(model.scales, device=device),
        "quats": torch.tensor(model.quats, device=device),
        "opacities": torch.tensor(model.opacities, device=device),
        "colors": torch.tensor(model.colors, device=device),
    }

    rendered: list[Keyframe] = []
    for identifier, (frame, pose, exact) in enumerate(_poses(bundle, extra_views)):
        view = _view(frame, device, camera_from_world=pose)
        with torch.no_grad():
            image = _rasterize(parameters, view, device)

        # Står vyn i ett fotos pose gäller fotots djupkarta ordagrant. Gör den
        # inte det finns ingen mätning att luta sig mot, och en gissning vore
        # sämre än inget: skymningstestet hoppas då över för just den vyn.
        rendered.append(Keyframe(
            id=identifier,
            camera_from_world=pose,
            intrinsics=view["intrinsics"],
            image_size=np.asarray(view["size"], np.float32),
            depth_size=frame.depth_size if exact else np.zeros(2, np.int32),
            image=(image.clamp(0, 1) * 255).to(torch.uint8).cpu().numpy(),
            depth=frame.depth if exact else None,
        ))

    log.info("renderade %d vyer ur splatten", len(rendered))
    return rendered


# MARK: - Insidan


def _device() -> str:
    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("gaussian splatting kräver CUDA — ingen GPU hittades")
    return "cuda"


def _seed(bundle: ScanBundle, max_splats: int) -> tuple[np.ndarray, np.ndarray]:
    """Startpunkter ur LiDAR-ytan, med skala satt av grannavståndet."""
    from scipy.spatial import cKDTree

    positions = np.unique(bundle.mesh.positions.reshape(-1, 3), axis=0).astype(np.float32)
    if len(positions) > max_splats:
        index = np.random.default_rng(0).choice(len(positions), max_splats, replace=False)
        positions = positions[index]

    # En gaussare ska täcka ungefär hålet till sin granne, annars syns nätet.
    distance, _ = cKDTree(positions).query(positions, k=2)
    spacing = np.maximum(distance[:, 1], 1e-3).astype(np.float32)
    scales = np.repeat(spacing[:, None] * 0.5, 3, axis=1)
    return positions, scales


def _view(frame: Keyframe, device: str, camera_from_world: np.ndarray | None = None) -> dict:
    """Ett foto omräknat till det gsplat vill ha."""
    import torch

    height, width = frame.image.shape[:2]
    # Fotot kan ha skalats ned efter att intrinsics skrevs.
    intrinsics = frame.intrinsics.astype(np.float32).copy()
    if frame.image_size[0] > 0 and frame.image_size[1] > 0:
        intrinsics[0] *= width / float(frame.image_size[0])
        intrinsics[1] *= height / float(frame.image_size[1])

    pose = frame.camera_from_world if camera_from_world is None else camera_from_world
    viewmat = _ARKIT_TO_OPENCV @ pose.astype(np.float32)

    return {
        "viewmat": torch.tensor(viewmat, device=device)[None],
        "K": torch.tensor(intrinsics, device=device)[None],
        "image": torch.tensor(frame.image.astype(np.float32) / 255.0, device=device),
        "intrinsics": intrinsics,
        "size": (width, height),
    }


def _rasterize(parameters: dict, view: dict, device: str):
    import torch
    from gsplat import rasterization

    width, height = view["size"]
    render, _, _ = rasterization(
        means=parameters["means"],
        quats=torch.nn.functional.normalize(parameters["quats"], dim=-1),
        scales=torch.exp(parameters["scales"]),
        opacities=torch.sigmoid(parameters["opacities"]),
        colors=parameters["colors"],
        viewmats=view["viewmat"],
        Ks=view["K"],
        width=width,
        height=height,
        render_mode="RGB",
    )
    return render[0, ..., :3]


def _poses(bundle: ScanBundle,
           extra_views: int) -> list[tuple[Keyframe, np.ndarray, bool]]:
    """De riktiga poserna, med några inskjutna emellan.

    Flaggan säger om posen är ett fotos egen. Bara då finns en uppmätt djupkarta
    som gäller för vyn.
    """
    frames = bundle.keyframes
    poses: list[tuple[Keyframe, np.ndarray, bool]] = []

    for index, frame in enumerate(frames):
        poses.append((frame, frame.camera_from_world, True))
        if extra_views <= 0 or index + 1 >= len(frames):
            continue

        following = frames[index + 1]
        for step in range(1, extra_views + 1):
            fraction = step / (extra_views + 1)
            poses.append((frame, _between(frame.camera_from_world,
                                          following.camera_from_world, fraction), False))
    return poses


def _between(first: np.ndarray, second: np.ndarray, fraction: float) -> np.ndarray:
    """En pose mellan två andra.

    Rotationen glids i kvaternionrummet och ortonormaliseras efteråt — en rak
    interpolation av matriserna hade skalat rummet på vägen.
    """
    from scipy.spatial.transform import Rotation, Slerp

    world_from = [np.linalg.inv(first), np.linalg.inv(second)]
    rotations = Rotation.from_matrix([pose[:3, :3] for pose in world_from])
    rotation = Slerp([0.0, 1.0], rotations)([fraction])[0]

    result = np.eye(4, dtype=np.float32)
    result[:3, :3] = rotation.as_matrix()
    result[:3, 3] = (1 - fraction) * world_from[0][:3, 3] + fraction * world_from[1][:3, 3]
    return np.linalg.inv(result).astype(np.float32)
