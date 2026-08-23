"""På vilken SKALA sitter färgbruset?

Kulörtaket klämmer mot medelvärdet i en ruta på två centimeter, och det tog bara
sex procent av felet. Antingen är gaussarna redan eniga inom två centimeter och
oense på längre håll — då är taket lagt på fel skala — eller så är de oense även
inom rutan och taket verkningslöst av något annat skäl.

Tabellen delar upp kulörspridningen i den som finns INOM rutorna och den mellan
rutornas medelvärden, för rutor av olika storlek. Den skala där spridningen
mellan rutor tar över är den skala felet lever på.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from splat_check import read_spz

model = read_spz(Path(sys.argv[1]))
colors = model.colors.astype(np.float64)
chroma = np.stack([colors[:, 0] - colors[:, 1], colors[:, 2] - colors[:, 1]], axis=1)
print(f"{len(model)} gaussare, kulörspridning totalt "
      f"{np.hypot(chroma[:, 0].std(), chroma[:, 1].std()) * 255:.2f} grånivåer\n")

print(f"{'ruta':>6} {'rutor':>10} {'inom':>8} {'mellan':>8}")
for size in (0.02, 0.05, 0.10, 0.20, 0.50):
    keys = np.floor(model.means.astype(np.float64) / size).astype(np.int64)
    _, group = np.unique(keys, axis=0, return_inverse=True)
    count = np.bincount(group).astype(np.float64)
    means = np.stack([np.bincount(group, weights=chroma[:, i]) / count for i in range(2)], axis=1)
    within = chroma - means[group]
    print(f"{size:>6.2f} {len(count):>10} "
          f"{np.hypot(within[:, 0].std(), within[:, 1].std()) * 255:>8.2f} "
          f"{np.hypot(means[:, 0].std(), means[:, 1].std()) * 255:>8.2f}")
