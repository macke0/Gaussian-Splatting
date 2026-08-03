"""Renderar den bakade mesh:en från ett fotos pose, bredvid fotot självt.

Atlasbilden säger ingenting om hur rummet SER UT — den kan mäta skarpt och ändå
vara fel uppvecklad, och glipor mellan xatlas rutor ser ut som hål fast de aldrig
samplas i 3D. Det här är kontrollen som håller: samma vy, vår rendering till
vänster, originalfotot till höger. Skiljer de sig åt är felet vårt.

    .venv/bin/python tools/render_check.py <bakad mapp> <skanningsmapp> [foto]
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, ".")
from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.mesh import TexturedMesh  # noqa: E402

Image.MAX_IMAGE_PIXELS = None

baked = Path(sys.argv[1])
room = Path(sys.argv[2])
which = int(sys.argv[3]) if len(sys.argv) > 3 else 0

mesh = TexturedMesh.decode((baked / "baked.mesh").read_bytes())
texture = np.asarray(Image.open(baked / "baked.png").convert("RGB"))
bundle = ScanBundle.load(room)
keyframe = bundle.keyframes[which]

print(f"mesh: {len(mesh.positions)} hörn, {len(mesh.indices)} trianglar")
print(f"atlas: {texture.shape}")
print(f"uv: min {mesh.uvs.min(axis=0)}, max {mesh.uvs.max(axis=0)}")

edges = np.linalg.norm(mesh.positions[mesh.indices[:, 1]]
                       - mesh.positions[mesh.indices[:, 0]], axis=1)
print(f"kantlängd: median {np.median(edges)*100:.1f} cm, "
      f"95:e percentil {np.percentile(edges, 95)*100:.1f} cm, "
      f"max {edges.max()*100:.1f} cm")

width, height = 480, 640
scale = width / keyframe.image_size[0]
intrinsics = keyframe.intrinsics.copy()
intrinsics[:2] *= scale

homogeneous = np.concatenate(
    [mesh.positions, np.ones((len(mesh.positions), 1), np.float32)], axis=1)
camera = homogeneous @ keyframe.camera_from_world.T
depth = -camera[:, 2]
pinhole = np.stack([camera[:, 0], -camera[:, 1], np.maximum(depth, 1e-6)], axis=1)
projected = pinhole @ intrinsics.T
pixels = projected[:, :2] / projected[:, 2:3]

image = np.full((height, width, 3), 20, np.uint8)
zbuffer = np.full((height, width), np.inf, np.float32)
atlas_size = texture.shape[0]

drawn = 0
for face in mesh.indices:
    if np.any(depth[face] <= 0.05):
        continue
    triangle = pixels[face]
    x0, y0 = np.floor(triangle.min(axis=0)).astype(int)
    x1, y1 = np.ceil(triangle.max(axis=0)).astype(int)
    x0, y0 = max(x0, 0), max(y0, 0)
    x1, y1 = min(x1, width), min(y1, height)
    if x1 <= x0 or y1 <= y0 or (x1 - x0) * (y1 - y0) > 40000:
        continue

    a, b, c = triangle
    area = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
    if abs(area) < 1e-9:
        continue

    grid_x, grid_y = np.meshgrid(np.arange(x0, x1), np.arange(y0, y1))
    ox = grid_x.ravel() + 0.5 - a[0]
    oy = grid_y.ravel() + 0.5 - a[1]
    wb = (ox * (c[1] - a[1]) - oy * (c[0] - a[0])) / area
    wc = ((b[0] - a[0]) * oy - (b[1] - a[1]) * ox) / area
    wa = 1 - wb - wc
    inside = (wa >= 0) & (wb >= 0) & (wc >= 0)
    if not inside.any():
        continue

    weights = np.stack([wa, wb, wc], axis=1)[inside]
    rows = grid_y.ravel()[inside]
    columns = grid_x.ravel()[inside]
    z = weights @ depth[face]
    nearer = z < zbuffer[rows, columns]
    if not nearer.any():
        continue

    uv = weights[nearer] @ mesh.uvs[face]
    tx = np.clip((uv[:, 0] * atlas_size).astype(int), 0, atlas_size - 1)
    ty = np.clip((uv[:, 1] * atlas_size).astype(int), 0, atlas_size - 1)
    image[rows[nearer], columns[nearer]] = texture[ty, tx]
    zbuffer[rows[nearer], columns[nearer]] = z[nearer]
    drawn += 1

print(f"ritade {drawn} trianglar, {np.isfinite(zbuffer).mean()*100:.0f} % av bilden täckt")

photo = Image.fromarray(keyframe.image).resize((width, height))
side = Image.new("RGB", (width * 2, height))
side.paste(Image.fromarray(image), (0, 0))
side.paste(photo, (width, 0))
side.save("/tmp/render.png")
print("skrev /tmp/render.png")
