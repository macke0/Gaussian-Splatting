"""Var i rummet saknar splatten mätt yta att sitta på?

Gaussarna hålls vid LiDAR-ytan av ``MAXIMUM_DRIFT``. Där ytan saknas har de
inget att hänga på och dras i stället mot närmaste ytpunkt, som brukar vara en
vägg några meter bort — och det ser ut som mjölkig smet i just det området.

Ett smetigt område med noll ytpunkter bakom sig är alltså ett hål i indata och
ingenting annat. Skriptet svarar på två frågor:

1. Hur fördelar sig den mätta ytan i höjd? Ett rum utan tak i meshen kan inte
   få ett skarpt tak i splatten, hur många foton och gaussare man än lägger på.
2. Hur stor del av varje foto har mätt yta bakom sig? Det talet är taket för
   hur skarp den vyn kan bli.

Körs mot en uppackad skanning:

    python tools/coverage_check.py /tmp/bake-<jobb>-<slump>/room
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from spatialfit_server.bundle import ScanBundle, connected_surface  # noqa: E402

CELLS = 8

room = Path(sys.argv[1])
bundle = ScanBundle.load(room)
surface, _ = connected_surface(bundle.mesh)

print(f"{len(bundle.keyframes)} foton, {len(surface)} ytpunkter efter städning")

# 1. Höjdprofilen. ARKits y är uppåt.
height = surface[:, 1]
floor, ceiling = height.min(), height.max()
print(f"\nhöjd {floor:.2f} … {ceiling:.2f} m, alltså {ceiling - floor:.2f} m")
edges = np.linspace(floor, ceiling, 11)
counts, _ = np.histogram(height, bins=edges)
for low, high, count in zip(edges[:-1], edges[1:], counts):
    share = count / len(surface)
    print(f"  {low:5.2f}–{high:5.2f} m  {count:8d}  {share:6.1%}  "
          + "#" * int(share * 200))

# 2. Täckningen per foto. Ett rutnät räcker: det är stora sjok som saknas,
#    inte enskilda pixlar.
print(f"\ntäckning per foto ({CELLS}×{CELLS} rutor med minst en ytpunkt)")
covered = []
for frame in bundle.keyframes:
    pixels, depth = frame.project(surface)
    width, height_px = frame.image.shape[1], frame.image.shape[0]
    scale = np.array([width / frame.image_size[0], height_px / frame.image_size[1]])
    pixels = pixels * scale

    inside = ((depth > 0)
              & (pixels[:, 0] >= 0) & (pixels[:, 0] < width)
              & (pixels[:, 1] >= 0) & (pixels[:, 1] < height_px))
    cells = np.zeros((CELLS, CELLS), bool)
    if inside.any():
        columns = (pixels[inside, 0] / width * CELLS).astype(int)
        rows = (pixels[inside, 1] / height_px * CELLS).astype(int)
        cells[np.clip(rows, 0, CELLS - 1), np.clip(columns, 0, CELLS - 1)] = True
    covered.append(cells)

covered = np.array(covered)
per_frame = covered.reshape(len(covered), -1).mean(axis=1)
order = np.argsort(per_frame)
print(f"  median {np.median(per_frame):.0%}, "
      f"sämsta {per_frame[order[0]]:.0%} (foto {order[0]}), "
      f"bästa {per_frame[order[-1]]:.0%} (foto {order[-1]})")

print("\nandel foton med mätt yta i rutan (uppifrån och ned):")
for row in covered.mean(axis=0):
    print("  " + " ".join(f"{value:5.0%}" for value in row))
