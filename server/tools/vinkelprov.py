"""Ser rummet bra ut från ALLA håll, eller bara från ett?

Det är den enda fråga som räknas för kunden, och den har hittills bara besvarats
med ögonmått på två skärmdumpar. Här ställs den i stället som ett prov: härma
visarens kamera i Python, ta den runt hela varvet, och rendera.

Två banor jämförs, för att skillnaden ska gå att se och inte bara påstås:

    orbit   den GAMLA: kretsar kring en punkt på 35 % av vägen till väggen.
            Den kunde hamna en decimeter in i soffan.
    gang    den NYA: kameran står i rummet, går längs blicken och stoppas
            `MARGIN` från närmaste gaussare (`SplatRoomView.blocked`).

Bilderna sparas i ett rutnät per bana — en rad per plats, en kolumn per väderstreck
— så att "bara en vinkel är bra" antingen syns direkt eller inte finns.

    .venv/bin/python tools/vinkelprov.py <skanningsmapp> <modell.ply> <utmapp>
"""
import dataclasses
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import _device, _rasterize, _view  # noqa: E402
from splat_check import read_ply, read_spz  # noqa: E402

#: Samma tre tal som `SplatRoomView`. Ändras de där måste de ändras här, annars
#: provar det här skriptet en kamera som inte finns.
CELL, MARGIN, SOLID = 0.15, 0.4, 0.3

#: Hur långt ut den gamla banan ställde kameran, som andel av rummets radie.
ORBIT_REACH = 0.35

YAWS = [0, 90, 180, 270]


def occupancy(means: np.ndarray, opacities: np.ndarray) -> set:
    """Kuberna gaussarna fyller — `SplatRoomView.occupancy(of:)`."""
    solid = means[1 / (1 + np.exp(-opacities)) >= SOLID]
    return set(map(tuple, np.floor(solid / CELL).astype(np.int32)))


def blocked(point: np.ndarray, cells: set, ball: np.ndarray) -> bool:
    """Står något närmare punkten än `MARGIN`? — `SplatRoomView.blocked(at:)`."""
    around = np.floor((point + ball) / CELL).astype(np.int32)
    return any(tuple(cell) in cells for cell in around)


def heading(yaw: float, pitch: float) -> np.ndarray:
    """Blickriktningen ur `yaw` och `pitch` — `SplatRoomView.heading`."""
    return -np.array([np.cos(pitch) * np.sin(yaw), np.sin(pitch),
                      np.cos(pitch) * np.cos(yaw)], np.float32)


def camera_from_world(eye: np.ndarray, forward: np.ndarray) -> np.ndarray:
    """ARKit-posen för en kamera i `eye` som tittar åt `forward`.

    Kameran ser längs sitt eget minus-Z, så basens tredje axel är bakåt.
    """
    back = -forward / np.linalg.norm(forward)
    right = np.cross([0, 1, 0], back)
    right /= np.linalg.norm(right)
    up = np.cross(back, right)

    rotation = np.stack([right, up, back])
    pose = np.eye(4, dtype=np.float32)
    pose[:3, :3] = rotation
    pose[:3, 3] = -rotation @ eye
    return pose


def walk(start: np.ndarray, yaw: float, steps: int, cells: set, ball: np.ndarray,
         low: np.ndarray, high: np.ndarray) -> np.ndarray:
    """Går så långt åt ett håll som spärren tillåter."""
    eye = start.copy()
    direction = heading(yaw, 0)
    for _ in range(steps):
        target = eye + 0.25 * direction
        if np.any(target < low) or np.any(target > high):
            break
        if blocked(target, cells, ball):
            break
        eye = target
    return eye


def main() -> None:
    import torch

    room, model_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    out.mkdir(parents=True, exist_ok=True)

    cull = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0

    bundle = ScanBundle.load(room)
    model = read_spz(model_path) if model_path.suffix == ".spz" else read_ply(model_path)
    device = _device()

    if cull:
        # Ingenting verkligt kan ligga där telefonen låg — den var där. Gaussare
        # inom `cull` från en kamerapose är alltså per definition påhitt, och de
        # kostar oproportionerligt: en gaussare fem centimeter från linsen täcker
        # hela skärmen. De överlever för att INGEN träningsvy tittar bakåt.
        from scipy.spatial import cKDTree
        eyes = np.array([np.linalg.inv(frame.camera_from_world)[:3, 3]
                         for frame in bundle.keyframes])
        distance, _ = cKDTree(eyes).query(model.means)
        keep = distance >= cull
        print(f"rensar {int((~keep).sum())} gaussare inom {cull} m från en kamera")
        model = dataclasses.replace(
            model, means=model.means[keep], quats=model.quats[keep],
            scales=model.scales[keep], opacities=model.opacities[keep],
            colors=model.colors[keep])

    parameters = {
        "means": torch.tensor(model.means, device=device),
        "scales": torch.tensor(model.scales, device=device),
        "quats": torch.tensor(model.quats, device=device),
        "opacities": torch.tensor(model.opacities, device=device),
        "colors": torch.tensor(model.colors, device=device),
    }

    # Percentilram, inte min/max: enstaka gaussare hamnar hundratals meter bort
    # och skulle annars bestämma hela rummets storlek.
    low = np.percentile(model.means, 1, axis=0).astype(np.float32)
    high = np.percentile(model.means, 99, axis=0).astype(np.float32)
    center = (low + high) / 2
    radius = float((high - low).max() / 2)

    # Fotografens medelpunkt, det visaren får som `standingAt`.
    standing = np.mean([np.linalg.inv(frame.camera_from_world)[:3, 3]
                        for frame in bundle.keyframes], axis=0).astype(np.float32)

    cells = occupancy(model.means, model.opacities)
    reach = int(np.ceil(MARGIN / CELL))
    offsets = np.arange(-reach, reach + 1)
    grid = np.stack(np.meshgrid(offsets, offsets, offsets, indexing="ij"), -1).reshape(-1, 3)
    ball = grid[(grid ** 2).sum(1) <= reach ** 2].astype(np.float32) * CELL

    print(f"{len(model)} gaussare, låda {high - low} m")
    print(f"fotografens mitt {standing.round(2)}, "
          f"{'BLOCKERAD' if blocked(standing, cells, ball) else 'fri'}")
    print(f"beläggning: {len(cells)} kuber")

    # Tre platser per bana. Den gående går ut åt tre håll från fotografens mitt;
    # den kretsande ställs på tre punkter i sin egen cirkel.
    #
    # `foto` är provet som skiljer PLATS från RIKTNING, och det är det enda som
    # avgör saken: kameran ställs exakt där ett riktigt foto togs — en plats som
    # per definition är giltig, för någon stod där — och vrids sedan på stället.
    # Håller bilden hela varvet är felet att vyn hamnat på fel PLATS. Faller den
    # isär när man vrider är det RIKTNINGEN, och då hjälper ingen kamerabana.
    turning = []
    for index in (0, len(bundle.keyframes) // 2, len(bundle.keyframes) - 1):
        world = np.linalg.inv(bundle.keyframes[index].camera_from_world)
        forward = -world[:3, 2]
        # Fotots egen riktning blir första kolumnen, så att raden börjar i en vy
        # som MÅSTE vara riktig och sedan visar vad som händer när man vrider.
        turning.append((f"foto{index}", world[:3, 3],
                        float(np.arctan2(-forward[0], -forward[2]))))

    places = {
        "foto": turning,
        "gang": [("mitt", standing, 0.0)] + [
            (f"gang{int(np.degrees(yaw))}",
             walk(standing, yaw, 12, cells, ball, low, high), 0.0)
            for yaw in (np.pi / 2, np.pi)],
        "orbit": [
            (f"orbit{int(np.degrees(yaw))}",
             center - ORBIT_REACH * radius * heading(yaw, 0.3), 0.0)
            for yaw in (0, np.pi / 2, np.pi)],
    }

    frame = bundle.keyframes[0]
    for path, spots in places.items():
        rows = []
        for name, eye, base in spots:
            distance = min(np.linalg.norm(eye - m) for m in model.means[::997])
            print(f"{path}/{name}: {eye.round(2)}, "
                  f"{np.linalg.norm(eye - standing):.2f} m från mitten, "
                  f"~{distance:.2f} m till närmaste gaussare")
            tiles = []
            for degrees in YAWS:
                pose = camera_from_world(eye, heading(base + np.radians(degrees), 0.0))
                view = _view(frame, device, camera_from_world=pose)
                with torch.no_grad():
                    image, _ = _rasterize(parameters, view, device)
                tiles.append(np.clip(image.cpu().numpy() * 255, 0, 255).astype(np.uint8))
            rows.append(np.hstack(tiles))
        sheet = Image.fromarray(np.vstack(rows))
        sheet.thumbnail((2048, 2048))
        sheet.save(out / f"{path}.jpg", quality=88)
        print(f"skrev {out / path}.jpg")


if __name__ == "__main__":
    main()
