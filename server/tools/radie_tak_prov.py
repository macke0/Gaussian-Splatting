"""Prövar olika radietak på en FÄRDIGTRÄNAD splat, utan att träna om.

Att släppa ``MAXIMUM_RADIUS`` fritt tog bort kornet men gav i stället stora
plattor som smetar ut sig över släta ytor — ett vitt tak renderades svart.
Kornmåttet ser inte det, eftersom ett utsmetat plan har LÅG variation och
alltså belönas. Frågan är därför var taket ska ligga, inte om det ska finnas.

Här klipps de största gaussarna helt enkelt bort ur en tränad modell och samma
vy renderas om för varje tak. Det svarar inte på vad träningen hade gjort med
taket på plats — den hade fördelat om massan — men det visar direkt OM de stora
är det som förstör bilden, och det tar sekunder i stället för nio minuter.

    python tools/radie_tak_prov.py <skanningsmapp> <modell.ply> <utmapp> <bildruta> [tak_mm ...]
"""
import dataclasses
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import synthetic_keyframes  # noqa: E402
from splat_check import read_ply  # noqa: E402

room, model_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
frame = int(sys.argv[4])
caps = [float(argument) for argument in sys.argv[5:]] or [1000.0, 200.0, 100.0, 50.0, 25.0]
out.mkdir(parents=True, exist_ok=True)

bundle = ScanBundle.load(room)
model = read_ply(model_path)

# Splatten är skarp i de poser den tränade fram, inte i ARKits. Utan det här
# jämförs modellen med en vy den aldrig såg och allt ser suddigt ut.
if model.poses is not None:
    bundle = dataclasses.replace(bundle, keyframes=[
        dataclasses.replace(existing, camera_from_world=pose)
        for existing, pose in zip(bundle.keyframes, model.poses)])

photo = np.asarray(bundle.keyframes[frame].image, dtype=np.uint8)
Image.fromarray(photo).save(out / "foto.png")

largest = np.exp(model.scales).max(axis=1) * 1000.0
for cap in caps:
    keep = largest <= cap
    trimmed = dataclasses.replace(
        model,
        means=model.means[keep], quats=model.quats[keep], scales=model.scales[keep],
        opacities=model.opacities[keep], colors=model.colors[keep])
    rendered = synthetic_keyframes(trimmed, bundle, extra_views=0)[frame]
    Image.fromarray(np.asarray(rendered.image, dtype=np.uint8)).save(
        out / f"tak{int(cap):04d}.png")
    error = float(np.abs(np.asarray(rendered.image, dtype=np.float64) - photo).mean())
    print(f"tak {cap:7.1f} mm  {int(keep.sum()):>9} gaussare "
          f"({100 * (1 - keep.mean()):5.2f} % bort)  L1 {error:6.2f}")
