"""Kan ett neuralt nät gissa tillbaka detaljen som splatten smetade bort?

Frågan är rimlig och skiljer sig från att stoppa AI i träningen: en STILLBILD
har inga krav på konsistens mellan vyer, så den vanliga invändningen — att
gissad detalj flimrar när betraktaren rör sig — gäller inte. Men ett skärpefilter
gör alltid bilden skarpare, så "blev det skarpare?" är en fråga som inte kan
besvaras med nej och därför inte är värd att ställa.

**Vi har facit.** COLMAP har löst poserna för varje foto i skanningen, så
splatten kan renderas ur EXAKT den pose ett riktigt fotografi togs i. Då blir
frågan i stället mätbar och tvåsidig:

    rörde sig bilden mot fotot, eller ifrån det?

Rör den sig mot fotot har nätet ÅTERSKAPAT något som fanns. Rör den sig ifrån
medan den ser skarpare ut har det HITTAT PÅ, och då är den skarpa bilden mer
missvisande än den suddiga — särskilt i ett verktyg som säljs på att måtten
stämmer.

Två mått, för det ena räcker inte:

* **L1** mot fotot, hela bilden. Fångar om något gick riktigt fel.
* **Högfrekvent L1**, båda bilderna högpassade först. Global L1 kan förbättras
  av att bilden bara blev piggare i kontrasten, utan att en enda kant hamnade
  rätt. Det är detaljen vi vill veta något om, alltså är det detaljen som mäts.

Metoderna jämförs mot en KLASSISK baslinje (``oskarp``, vanlig oskarp maskning)
och inte bara mot originalet. Slår det neurala nätet inte en oskarp mask är det
inte värt en modellfil på 67 MB i pipelinen.

    .venv/bin/python tools/uppskalning_check.py <modell.ply> <skanningsmapp> \
        --forfinade <arbetsyta> [--vy N] [--utsnitt x,y,bredd,höjd] \
        [--vikter RealESRGAN_x4plus.pth]

``--utsnitt`` klipper ut samma ruta ur alla tre bilderna och skriver den i 1:1.
**Använd den.** Regel noll i det här projektet är att titta på bilden: varje
skärpemått vi har är blint för det ögat ser, nu sex gånger om. Välj både ett
lätt motiv (en list — rak kant med repeterad profil, nätens allra enklaste fall)
och ett svårt (text, växtens blad, en tavelrams ornament). Klarar nätet listen
men hittar på blad vet vi precis var gränsen går.
"""

from __future__ import annotations

import sys
from dataclasses import replace
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import gaussian_filter

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from spatialfit_server import poses  # noqa: E402
from spatialfit_server.bundle import ScanBundle  # noqa: E402
from spatialfit_server.splat import synthetic_keyframes  # noqa: E402
from splat_check import read_ply  # noqa: E402

#: Bredden på högpassfiltret i pixlar. Allt grövre än så är ljussättning och
#: färg, inte detalj, och det är detaljen frågan gäller.
HIGHPASS_SIGMA = 2.0

#: Oskarp maskning: styrka och radie. Baslinjen ska vara en ärlig motståndare,
#: alltså ungefär så hårt man vågar skärpa innan halofransarna syns.
UNSHARP_AMOUNT = 1.0
UNSHARP_SIGMA = 1.5


def _highpass(image: np.ndarray) -> np.ndarray:
    return image - gaussian_filter(image, (HIGHPASS_SIGMA, HIGHPASS_SIGMA, 0))


def _scores(candidate: np.ndarray, truth: np.ndarray) -> tuple[float, float]:
    """L1 mot fotot, hela bilden och bara detaljen."""
    return (float(np.abs(candidate - truth).mean()),
            float(np.abs(_highpass(candidate) - _highpass(truth)).mean()))


def _unsharp(image: np.ndarray) -> np.ndarray:
    blurred = gaussian_filter(image, (UNSHARP_SIGMA, UNSHARP_SIGMA, 0))
    return np.clip(image + UNSHARP_AMOUNT * (image - blurred), 0, 1)


def _rrdbnet(weights: Path):
    """Real-ESRGAN:s generator i ren torch.

    Byggd för hand med flit. Vägen via ``basicsr``/``spandrel`` drar in
    torchvision, som i sin tur uppgraderar torch och slår sönder gsplats
    förkompilerade kernels — hela bakningen låg nere en gång på det. Nätet är
    sjuttio rader; det är billigare än att laga miljön igen.
    """
    import torch
    from torch import nn
    from torch.nn import functional

    class Dense(nn.Module):
        def __init__(self, features: int = 64, growth: int = 32):
            super().__init__()
            for index in range(1, 6):
                inputs = features + (index - 1) * growth
                outputs = growth if index < 5 else features
                setattr(self, f"conv{index}", nn.Conv2d(inputs, outputs, 3, 1, 1))
            self.relu = nn.LeakyReLU(0.2, inplace=True)

        def forward(self, x):
            outputs = [x]
            for index in range(1, 5):
                outputs.append(self.relu(
                    getattr(self, f"conv{index}")(torch.cat(outputs, 1))))
            return self.conv5(torch.cat(outputs, 1)) * 0.2 + x

    class Block(nn.Module):
        def __init__(self, features: int, growth: int = 32):
            super().__init__()
            self.rdb1, self.rdb2, self.rdb3 = (Dense(features, growth) for _ in range(3))

        def forward(self, x):
            return self.rdb3(self.rdb2(self.rdb1(x))) * 0.2 + x

    class Net(nn.Module):
        def __init__(self, features: int = 64, blocks: int = 23, growth: int = 32):
            super().__init__()
            self.conv_first = nn.Conv2d(3, features, 3, 1, 1)
            self.body = nn.Sequential(*[Block(features, growth) for _ in range(blocks)])
            self.conv_body = nn.Conv2d(features, features, 3, 1, 1)
            self.conv_up1 = nn.Conv2d(features, features, 3, 1, 1)
            self.conv_up2 = nn.Conv2d(features, features, 3, 1, 1)
            self.conv_hr = nn.Conv2d(features, features, 3, 1, 1)
            self.conv_last = nn.Conv2d(features, 3, 3, 1, 1)
            self.relu = nn.LeakyReLU(0.2, inplace=True)

        def forward(self, x):
            first = self.conv_first(x)
            feature = first + self.conv_body(self.body(first))
            for convolution in (self.conv_up1, self.conv_up2):
                feature = self.relu(convolution(
                    functional.interpolate(feature, scale_factor=2, mode="nearest")))
            return self.conv_last(self.relu(self.conv_hr(feature)))

    state = torch.load(weights, map_location="cpu", weights_only=True)
    net = Net()
    net.load_state_dict(state.get("params_ema", state.get("params", state)))
    return net.eval().cuda() if torch.cuda.is_available() else net.eval()


def _superresolved(image: np.ndarray, net) -> np.ndarray:
    """Fyrdubblar och krymper tillbaka.

    Renderingen har rätt upplösning men fel skärpa, så uppskalningen är bara
    vägen dit: nätet får hitta detalj i fyra gånger så många pixlar, och sedan
    trycks bilden ihop till samma format som fotot så de går att jämföra.
    """
    import torch

    device = next(net.parameters()).device
    tensor = torch.from_numpy(image.transpose(2, 0, 1)).unsqueeze(0).to(device)
    with torch.no_grad():
        large = net(tensor).clamp(0, 1)
        small = torch.nn.functional.interpolate(
            large, size=image.shape[:2], mode="area")
    return small[0].cpu().numpy().transpose(1, 2, 0)


def _strip(images: list[np.ndarray], path: Path) -> None:
    height = max(item.shape[0] for item in images)
    width = sum(item.shape[1] for item in images)
    strip = Image.new("RGB", (width, height))
    offset = 0
    for item in images:
        strip.paste(Image.fromarray((item * 255).round().astype(np.uint8)), (offset, 0))
        offset += item.shape[1]
    strip.save(path)


def main(argv: list[str] | None = None) -> int:
    arguments = argv if argv is not None else sys.argv[1:]

    def option(name: str, fallback=None):
        if name not in arguments:
            return fallback
        return arguments[arguments.index(name) + 1]

    workspace = option("--forfinade")
    # Flera vyer per körning: COLMAP-förfiningen tar sex minuter och behöver
    # bara göras en gång, medan ett enskilt motiv sällan avgör något.
    views = [int(value) for value in str(option("--vy", "0")).split(",")]
    crop = option("--utsnitt")
    weights = Path(option("--vikter", "/tmp/RealESRGAN_x4plus.pth"))
    positional = [item for index, item in enumerate(arguments)
                  if not item.startswith("--")
                  and (index == 0 or not arguments[index - 1].startswith("--"))]
    if len(positional) < 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2

    room = Path(positional[1])
    bundle = ScanBundle.load(room)
    if workspace is not None:
        refined = poses.refined(bundle, room, Path(workspace))
        if refined is None:
            print("COLMAP löste inte poserna", file=sys.stderr)
            return 1
        bundle = refined
    if any(not 0 <= view < len(bundle.keyframes) for view in views):
        print(f"vy utanför {len(bundle.keyframes)} foton", file=sys.stderr)
        return 1

    model = read_ply(Path(positional[0]))
    net = _rrdbnet(weights) if weights.exists() else None
    if net is None:
        print(f"hoppar över nätet, {weights} saknas\n")
    stem = Path(positional[0]).with_suffix("")
    print("mot det VERKLIGA fotot ur samma pose — lägre är närmare sanningen")

    for view in views:
        # Bara den vy vi mäter renderas. Att rendera alla trehundra tar minuter
        # och PLY:n bär inga egna poser, så det räcker att korta ned skanningen.
        single = replace(bundle, keyframes=[bundle.keyframes[view]])
        rendered = synthetic_keyframes(model, single, extra_views=0)[0].image

        photo = np.asarray(Image.fromarray(np.asarray(bundle.keyframes[view].image))
                           .resize((rendered.shape[1], rendered.shape[0])))
        truth = photo.astype(np.float32) / 255
        base = rendered.astype(np.float32) / 255

        variants = {"rendering": base, "oskarp mask": _unsharp(base)}
        if net is not None:
            variants["Real-ESRGAN"] = _superresolved(base, net)

        print(f"\nvy {view} av {len(bundle.keyframes)}, "
              f"{rendered.shape[1]}x{rendered.shape[0]}, {len(model)} gaussare")
        print(f"{'':<14} {'L1':>8} {'detalj-L1':>10}   mot renderingen")
        reference = None
        for name, image in variants.items():
            total, detail = _scores(image, truth)
            if reference is None:
                reference, verdict = detail, ""
            else:
                verdict = ("MOT fotot" if detail < reference else "IFRÅN fotot") \
                    + f" ({(detail - reference) / reference:+.1%} detalj-L1)"
            print(f"{name:<14} {total:>8.4f} {detail:>10.4f}   {verdict}")

        _strip(list(variants.values()) + [truth], Path(f"{stem}.vy{view}.png"))
        print(f"skrev {stem.name}.vy{view}.png "
              f"({' | '.join(list(variants) + ['FOTO'])})")

        if crop:
            x, y, width, height = (int(value) for value in crop.split(","))
            box = (slice(y, y + height), slice(x, x + width))
            _strip([image[box] for image in variants.values()] + [truth[box]],
                   Path(f"{stem}.vy{view}.utsnitt.png"))
            print(f"skrev {stem.name}.vy{view}.utsnitt.png i 1:1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
