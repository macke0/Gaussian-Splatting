"""Renderar HELA vyer ur en splat bredvid fotot de tränades mot.

`vagg_utsnitt.py` klipper ut 120 pixlar slät vägg för att mäta korn. Den här
gör tvärtom: hela bilden, i full upplösning, för att se vad ögat ser. Det gick
inte förr, när ingen bild kunde hämtas hem från boxen; med MTU:n lagad går det.

Poängen är att skilja "modellen är suddig" från "telefonen står där ingen
kamera stod". Vyerna ÄR kamerapositioner ur skanningen.

MEN: ge den en PLY ur en träningskörning, aldrig en SPZ. SPZ bär inga poser, och
splatten är skarp i de poser TRÄNINGEN landade på — inte i ARKits. Skillnaden är
liten i millimeter (~8 mm i median) och stor i pixlar: på två meters håll blir
det ca 0,26°, alltså runt 7 av 1536 pixlar, vilket räcker för att få en skarp
modell att se suddig ut. Utan poser gör raden nedan tyst ingenting, och bilden
ljuger. `--preview` i `train_splat.py` gör samma jämförelse rätt.

    python tools/vy_jamfor.py <skanningsmapp> <modell> <utmapp> [bildruta ...]
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
from splat_check import read_ply, read_spz  # noqa: E402

room, model_path, out = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
frames = [int(argument) for argument in sys.argv[4:]] or [10, 60, 120]
out.mkdir(parents=True, exist_ok=True)

bundle = ScanBundle.load(room)
model = read_spz(model_path) if model_path.suffix == ".spz" else read_ply(model_path)

# Gled kamerorna under träningen är det de JUSTERADE poserna splatten är skarp
# i. Renderar vi från ARKits ursprungliga jämför vi mot en vy modellen aldrig
# såg och drar fel slutsats om skärpan — samma fälla som `train_splat.py`
# varnar för. Fotot självt hör ihop med bildrutan, inte med posen, så det står
# kvar orört.
if model.poses is not None:
    bundle = dataclasses.replace(bundle, keyframes=[
        dataclasses.replace(frame, camera_from_world=pose)
        for frame, pose in zip(bundle.keyframes, model.poses)])

rendered = synthetic_keyframes(model, bundle, extra_views=0)

for frame in frames:
    photo = np.asarray(bundle.keyframes[frame].image, dtype=np.uint8)
    splat = np.asarray(rendered[frame].image, dtype=np.uint8)
    height, width = photo.shape[:2]
    pair = Image.new("RGB", (width * 2, height))
    pair.paste(Image.fromarray(photo), (0, 0))
    pair.paste(Image.fromarray(splat), (width, 0))
    pair.save(out / f"vy{frame:03d}.jpg", quality=88)
    print(f"vy{frame:03d}.jpg  {width}x{height}  foto | splat")
