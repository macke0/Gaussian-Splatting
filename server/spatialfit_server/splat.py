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

**Förtätning trots tät start.** Vanlig 3DGS börjar med glesa SfM-punkter och
måste klona sig fram till täckning. Vi börjar i LiDAR-ytans hörn — geometrin är
redan känd och tät, vilket är hela poängen med att ha skannat rummet. Men en
gaussare per LiDAR-hörn är ett tak på detaljnivån, och det taket ligger under
fotots: 200 000 hörn mot 40 foton à 1536 px. Därför får gsplat dela och klona
där bilden inte stämmer. Mätningen rörs inte — den kommer aldrig härifrån.

**Gaussarna hålls vid den mätta ytan.** Fritt tränad lägger sig en splat gärna
som dimma mellan kameran och väggen: många halvgenomskinliga klumpar mitt i
rummet sänker pixelfelet billigare än en skarp yta gör. Vanlig 3DGS har inget
att sätta emot, men vi har LiDAR-ytan. ``MAXIMUM_DRIFT`` och ``MAXIMUM_RADIUS``
säger därför att en gaussare ska sitta på det som mätts upp och vara stor som en
bit av det. Då finns inget billigt alternativ till att bli skarp.

Ytan de hålls vid är den *städade* — ``connected_surface``. Det är inte en
detalj: ARKit lämnar flagor som svävar fritt mitt i rummet, och en gaussare på
en flaga är brus som regeln ovan aldrig kan komma åt, för den sitter ju på
"ytan". Bakningen kastade flagorna redan; splatten sådde på dem.

**De startar som skivor, inte som klot — men får aldrig bli rakblad.** En vägg
beskrivs bäst av något platt som ligger an mot den. Vanlig 3DGS börjar med klot
för att den inte vet var ytan är; vi vet, och ger dem ytans normal och en tunn
tredje axel från början. ``MINIMUM_ASPECT`` sätter samtidigt en undre gräns för
hur avlång en gaussare får bli, för annars är nästa steg efter skivan nålen: en
nål syns inte alls från fotot den passades mot och som ett streck från alla
andra håll. Rummet ska gå att titta runt i, inte bara att stå still i.

**Poserna får glida, men bara för bildens skull.** De kommer från ARKit och
duger till att mäta med. Till att *måla* med gör de det inte: reprojektionsfelet
är 2–3 cm, vilket vid 1536 px är 15–20 pixlars glidning mellan två foton av samma
vägg. Tränar man en splat mot foton som är oense på den nivån blir resultatet ett
medelvärde av dem — suddigt, hur många gaussare och steg man än lägger på.
``refine_poses`` låter därför varje kamera justera sig några millimeter. Den
justeringen stannar i träningen och skrivs aldrig tillbaka till skanningen; det
som mäts kommer fortfarande från ARKits egna poser.

**Förlusten är inte bara L1.** Ett pixelavstånd är nöjt med ett medelvärde: två
foton som är oense om var väggen ligger får sin lägsta L1 av något suddigt
mittemellan. Därför väger ``SSIM_WEIGHT`` in strukturlikhet, som mäter lokal
kontrast och samvariation och alltså ser skillnad på skarpt och utsmetat.

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

from .atlas import vertex_normals
from .bundle import Keyframe, ScanBundle, connected_surface

log = logging.getLogger(__name__)

#: Antal gaussare att starta med. Fler ger skarpare bild men långsammare steg.
DEFAULT_MAX_SPLATS = 300_000
#: 3 000 räckte inte. Uppmätt på ett riktigt rum: skillnaden mot fotot går från
#: 24 till 8,7 grånivåer mellan 7 000 och 30 000 steg, och förtätningen slutar
#: ändå av sig själv vid halva vägen.
DEFAULT_ITERATIONS = 30_000
#: Hur många extra vyer som vävs in mellan de riktiga fotona.
DEFAULT_EXTRA_VIEWS = 2
#: Så många gaussare telefonen får. Formatet är 68 byte styck, så 400 000 är
#: ungefär 27 MB att ladda ner och lika mycket i GPU-minnet. Talet är också
#: träningens tak — se ``train``.
PHONE_SPLAT_BUDGET = 400_000

#: Nollte sfäriska harmoniken. Splat-visare lagrar färgen som SH-koefficient och
#: räknar tillbaka den som ``0.5 + SH_DC * f_dc``.
SH_DC = 0.28209479177387814

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
    #: Kamerorna som träningen landade på, om de fick justeras. Bara till för att
    #: kunna rendera om splatten från samma håll — måtten använder dem aldrig.
    poses: np.ndarray | None = None  # (kameror, 4, 4)

    def __len__(self) -> int:
        return len(self.means)


LEARNING_RATES = {
    "scales": 5e-3,
    "quats": 1e-3,
    "opacities": 5e-2,
    "colors": 2.5e-2,
}

#: Takten för gaussarnas läge, skalad med rummets storlek som i 3DGS-artikeln.
#: Här satt fem gånger lägre förr, för att inte "kasta bort den mätta
#: geometrin". Det var fel resonemang: splatten mäter ingenting. En gaussare som
#: inte får flytta sig till rätt plats växer i stället tills den täcker felet,
#: och stora gaussare är precis vad ett utsmetat rum består av.
MEANS_LEARNING_RATE = 1.6e-4

#: Genomskinliga från början. Startar de nästan täckande blir de 200 000
#: överlappande gaussarna en vägg av dimma: den främsta äter hela alfat och
#: ytorna bakom får aldrig någon gradient att lära sig av.
INITIAL_OPACITY = 0.1

#: Kamerornas egen inlärningstakt. Låg med flit: felet vi rättar är centimeter,
#: inte meter, och en lös kamera hittar hellre en vacker lögn än rummet.
POSE_LEARNING_RATE = 1e-4

#: Hur mycket av förlusten som är strukturlikhet i stället för pixelavstånd.
#: Samma vikt som 3DGS-artikeln använder.
SSIM_WEIGHT = 0.2

#: MCMC-strategin håller antalet gaussare konstant genom att flytta de döda dit
#: bilden är fel. Utan de här två straffen driver den mot många nästan
#: genomskinliga och stora gaussare, eftersom en dimma sänker förlusten billigt.
#: Vikterna är gsplats egna.
OPACITY_PENALTY = 0.01
SCALE_PENALTY = 0.01

#: Svagare än så syns en gaussare inte ens som en aning. Nästan halva en
#: MCMC-tränad splat hamnar där, eftersom straffet ovan trycker ned alla som
#: inte behövs. Uppmätt på det riktiga rummet: att kasta dem nästan halverar
#: filen och kostar 0,14 dB — och den renderade bilden blir marginellt SKARPARE.
MINIMUM_OPACITY = 0.05

#: Hur långt utanför skanningens egen låda en gaussare får ligga. MCMC:s brus
#: slungar iväg ett par tusen stycken. De är osynliga men inte gratis: telefonen
#: ställer kameran efter splattens utsträckning, och med dem kvar mätte rummet
#: 1 343 meter i stället för 9.
ROOM_MARGIN = 1.0

#: Största radie en gaussare får ha. Ytan den ska beskriva är mätt med 12 mm
#: mellan hörnen; en gaussare på en halv meter beskriver ingen yta alls utan
#: lägger en färgtvätt över halva rummet. Det sänker pixelfelet billigt och är
#: precis vad ett dimmigt rum består av. Uppmätt på det riktiga rummet innan
#: taket fanns: största radien var 1,46 m, och de tio största satt mitt i luften.
MAXIMUM_RADIUS = 0.05

#: Hur långt från LiDAR-ytan en gaussare får driva. Ytan är mätt — en gaussare
#: som svävar en decimeter ut i rummet representerar ingenting som finns där.
#: Uppmätt utan gränsen: 74 % av gaussarna låg mer än 2 cm från ytan och bar
#: 91 % av den synliga massan, alltså var rummet mest dimma.
MAXIMUM_DRIFT = 0.02

#: Hur ofta de som drivit iväg dras tillbaka. Varje steg vore slöseri — en
#: gaussare rör sig bråkdelar av en millimeter per steg — och frågan mot
#: KD-trädet kostar en halv sekund för hela budgeten.
SURFACE_INTERVAL = 250

#: Hur avlång en gaussare får bli: minsta axeln delat med den största. Utan
#: gränsen växer den till ett rakblad — osynligt från fotot den passades mot,
#: eftersom den ses på högkant, men ett lysande streck så fort kameran flyttar
#: sig någon decimeter. Det är de strecken som gör rummet obrukbart att titta
#: runt i, och de kostar ingenting att träna fram: ett rakblad kan lägga sig
#: exakt längs en kant i ett enda foto.
#:
#: Taket ligger i logaritmen, där skalorna bor, så gränsen blir ett tillägg.
MINIMUM_ASPECT = 0.1

#: Hur tunn en startgaussare är tvärs ytan, som andel av avståndet till grannen.
#: En vägg beskrivs av skivor, inte av klot: ett klot med radien r suddar över r
#: åt alla håll, medan en skiva bara suddar längs väggen där färgen ändå är lik.
#: Uppmätt innan startriktningen fanns: hälften av de tränade gaussarna var
#: närmast klotformade (mellersta axeln 1,45 gånger den minsta i median), alltså
#: hittade optimeraren aldrig dit själv.
SEED_THICKNESS = 0.1


def train(bundle: ScanBundle,
          iterations: int = DEFAULT_ITERATIONS,
          max_splats: int = DEFAULT_MAX_SPLATS,
          densify: bool = True,
          refine_poses: bool = True,
          budget: int = PHONE_SPLAT_BUDGET) -> SplatModel:
    """Passar gaussare mot fotona. Kräver CUDA.

    ``budget`` är telefonens tak, och det gäller redan här. Förr sköt träningen
    fritt upp till några miljoner gaussare och exporten gallrade ner till taket
    efteråt — men gallringen mätte opacitet gånger volym, alltså valde den de
    STÖRSTA. En platt skiva som täcker en vägg skarpt har liten volym; en rund
    klump som smetar har stor. Exporten kastade alltså systematiskt bort det
    träningen lärt sig och behöll dimman. Uppmätt på det riktiga rummet: av den
    exporterade miljonen var hälften närmast klot (mid/min 1,45 i median),
    vilket är fel form för en yta.

    Därför äger träningen taket i stället, genom gsplats MCMC-strategi: antalet
    gaussare hålls konstant och de som slocknar flyttas dit bilden är fel. Det
    som skickas till telefonen är då exakt det som optimerades.
    """
    import torch
    from scipy.spatial import cKDTree

    device = _device()
    frames = [frame for frame in bundle.keyframes if frame.image.size]
    if not frames:
        raise ValueError("skanningen innehåller inga foton att träna på")

    # Ytan gaussarna både sås på och hålls vid, utan ARKits lösa flagor. Samma
    # yta som bakningen använder — annars blir flagorna brus i luften som
    # ``MAXIMUM_DRIFT`` inte kan se, eftersom de räknas som yta.
    surface, faces = connected_surface(bundle.mesh)
    log.info("ytan att träna mot: %d hörn av skanningens %d",
             len(surface), len(bundle.mesh.positions))

    means, scales, quats = _seed(surface, vertex_normals(surface, faces), max_splats)
    log.info("startar från %d punkter på LiDAR-ytan", len(means))

    parameters = torch.nn.ParameterDict({
        "means": torch.nn.Parameter(torch.tensor(means, device=device)),
        "scales": torch.nn.Parameter(torch.tensor(np.log(scales), device=device)),
        "quats": torch.nn.Parameter(torch.tensor(quats, device=device)),
        "opacities": torch.nn.Parameter(torch.full(
            (len(means),), float(np.log(INITIAL_OPACITY / (1 - INITIAL_OPACITY))), device=device)),
        # Grått är en ärligare gissning än svart: förlusten drar det åt rätt
        # håll oavsett rummets ton.
        "colors": torch.nn.Parameter(torch.full((len(means), 3), 0.5, device=device)),
    })
    # gsplats förtätningsstrategi flyttar rader i både parametrar och Adams
    # tillstånd, och kan bara göra det när varje parameter har en egen
    # optimerare. Därför en per namn i stället för en med fem grupper.
    scene_scale = max(float(np.linalg.norm(means.max(axis=0) - means.min(axis=0)) / 2), 1e-3)
    rates = dict(LEARNING_RATES, means=MEANS_LEARNING_RATE * scene_scale)
    optimizers = {name: torch.optim.Adam([{"params": parameters[name], "lr": rate, "name": name}])
                  for name, rate in rates.items()}

    # Takten för lägena trappas ned hundrafalt över träningen. Utan det fortsätter
    # gaussarna att skaka i sista steget lika mycket som i första, och en yta som
    # aldrig får stanna hinner aldrig bli skarp.
    schedule = torch.optim.lr_scheduler.ExponentialLR(
        optimizers["means"], gamma=0.01 ** (1.0 / max(iterations, 1)))

    strategy, state = _densification(budget) if densify else (None, None)

    # Hela ytan, inte de utglesade startpunkterna: det som ska hindras är drift
    # ut i rummet, och då gäller varje mätt punkt.
    tree = cKDTree(surface)

    views = [_view(frame, device) for frame in frames]
    generator = np.random.default_rng(0)

    # Kamerajusteringen hålls utanför `optimizers`: den ordboken tillhör
    # förtätningsstrategin, som förutsätter att varje post är en gaussarlista.
    deltas = None
    pose_optimizer = None
    if refine_poses:
        deltas = torch.nn.Parameter(torch.zeros(len(views), 6, device=device))
        pose_optimizer = torch.optim.Adam([deltas], lr=POSE_LEARNING_RATE)

    pulled = 0
    for step in range(iterations):
        index = int(generator.integers(len(views)))
        view = views[index]
        viewmat = view["viewmat"] if deltas is None else _nudged(view["viewmat"], deltas[index])
        rendered, info = _rasterize(parameters, view, device, viewmat)

        loss = ((1 - SSIM_WEIGHT) * (rendered - view["image"]).abs().mean()
                + SSIM_WEIGHT * (1 - _ssim(rendered, view["image"])))
        if strategy is not None:
            # Med ett fast antal gaussare är det billigt att lägga sig som dimma
            # över hela rummet: många halvgenomskinliga klumpar sänker
            # pixelfelet utan att någon yta blir skarp. Straffen gör dimman dyr,
            # så budgeten går till täta gaussare som sitter på en yta.
            loss = (loss
                    + OPACITY_PENALTY * torch.sigmoid(parameters["opacities"]).abs().mean()
                    + SCALE_PENALTY * torch.exp(parameters["scales"]).abs().mean())

        for optimizer in optimizers.values():
            optimizer.zero_grad(set_to_none=True)
        if pose_optimizer is not None:
            pose_optimizer.zero_grad(set_to_none=True)
        loss.backward()

        for optimizer in optimizers.values():
            optimizer.step()
        if pose_optimizer is not None:
            pose_optimizer.step()

        if strategy is not None:
            # Bruset som flyttar de slocknade gaussarna skalas med lägenas
            # inlärningstakt, och den trappas ned. Sent i träningen ska en
            # gaussare som hittat sin plats stå still.
            strategy.step_post_backward(params=parameters, optimizers=optimizers,
                                        state=state, step=step, info=info,
                                        lr=schedule.get_last_lr()[0])
        schedule.step()

        with torch.no_grad():
            parameters["colors"].clamp_(0.0, 1.0)
            parameters["scales"].clamp_(max=float(np.log(MAXIMUM_RADIUS)))
            # Ingen axel får bli en bråkdel av den längsta. Skalorna är
            # logaritmer, så förhållandet är en summa och golvet ett tillägg.
            parameters["scales"].clamp_(
                min=parameters["scales"].max(dim=1, keepdim=True).values
                + float(np.log(MINIMUM_ASPECT)))
            if step % SURFACE_INTERVAL == 0 or step == iterations - 1:
                moved, pulled = _pulled_to_surface(
                    parameters["means"].detach().cpu().numpy(), tree, surface)
                if pulled:
                    parameters["means"].copy_(torch.tensor(moved, device=device))

        if step % 500 == 0:
            log.info("steg %d/%d, förlust %.4f, %d gaussare, %d drog tillbaka",
                     step, iterations, float(loss.detach()), len(parameters["means"]), pulled)

    model = SplatModel(
        means=parameters["means"].detach().cpu().numpy(),
        quats=parameters["quats"].detach().cpu().numpy(),
        scales=parameters["scales"].detach().cpu().numpy(),
        opacities=parameters["opacities"].detach().cpu().numpy(),
        colors=parameters["colors"].detach().cpu().numpy(),
        poses=_refined(frames, views, deltas) if deltas is not None else None,
    )
    return _trimmed(model, bundle)


def write_ply(model: SplatModel, path) -> None:
    """Skriver splatten i 3DGS vanliga PLY-format.

    Färgen ligger som SH-nollterm, vilket är vad visarna väntar sig — därför
    omräkningen nedan.

    Ingen gallring sker här. Telefonens tak är träningens tak, så det som
    skrivs är det som optimerades — se ``train``.

    Ordningen är slumpad. Telefonen visar splatten medan den läses, och
    gaussarna ligger annars kvar i startpunkternas ordning — som är sorterad
    efter x, eftersom ``_seed`` går via ``np.unique``. Läser man den rakt av
    växer rummet fram som en vägg i taget och kameran, som ställs efter det
    inlästas låda, svänger med. Slumpad ordning gör att hela rummet syns direkt
    och bara förtätas.
    """
    from pathlib import Path

    count = len(model.means)
    fields = (["x", "y", "z", "nx", "ny", "nz"]
              + [f"f_dc_{channel}" for channel in range(3)]
              + ["opacity"]
              + [f"scale_{axis}" for axis in range(3)]
              + [f"rot_{component}" for component in range(4)])

    order = np.random.default_rng(0).permutation(count)
    table = np.zeros((count, len(fields)), np.float32)
    table[:, 0:3] = model.means[order]
    # Normalerna används inte av någon visare men hör till formatet.
    table[:, 6:9] = (model.colors[order] - 0.5) / SH_DC
    table[:, 9] = model.opacities[order]
    table[:, 10:13] = model.scales[order]
    table[:, 13:17] = model.quats[order]

    header = "\n".join(["ply", "format binary_little_endian 1.0",
                        f"element vertex {count}"]
                       + [f"property float {name}" for name in fields]
                       + ["end_header", ""])

    with Path(path).open("wb") as file:
        file.write(header.encode("ascii"))
        file.write(table.tobytes())
    log.info("skrev %d gaussare till %s", count, path)


def _pulled_to_surface(points: np.ndarray, tree, surface: np.ndarray) -> tuple[np.ndarray, int]:
    """De gaussare som drivit för långt ut, dragna tillbaka mot den mätta ytan.

    Dras till skalet ``MAXIMUM_DRIFT`` från ytan och inte hela vägen ned på den:
    riktningen den drev åt är oftast rätt — det är avståndet som är fel — och en
    gaussare som slängs ned på ytan varje gång tappar det den lärt sig.

    Att göra det här i stället för att straffa avståndet i förlusten är ett val:
    ytan är *mätt*, inte gissad, så det finns inget att väga den mot.
    """
    distance, nearest = tree.query(points, k=1)
    drifted = distance > MAXIMUM_DRIFT
    if not drifted.any():
        return points, 0

    outward = points[drifted] - surface[nearest[drifted]]
    outward /= np.linalg.norm(outward, axis=1, keepdims=True)
    moved = points.copy()
    moved[drifted] = surface[nearest[drifted]] + outward * MAXIMUM_DRIFT
    return moved, int(drifted.sum())


def _trimmed(model: SplatModel, bundle: ScanBundle) -> SplatModel:
    """Utan de osynliga och de bortflugna.

    Båda är rena kostnader: de laddas ner, sorteras om varje bildruta och
    behandlas av vertexskuggaren, utan att lämna en pixel efter sig. De
    bortflugna är dessutom aktivt skadliga — telefonen ställer kameran efter
    splattens låda, och några gaussare en kilometer bort lägger rummet utom
    synhåll.
    """
    import dataclasses

    corners = bundle.mesh.positions.reshape(-1, 3)
    low, high = corners.min(axis=0) - ROOM_MARGIN, corners.max(axis=0) + ROOM_MARGIN

    keep = (np.all((model.means >= low) & (model.means <= high), axis=1)
            & (model.opacities >= np.log(MINIMUM_OPACITY / (1 - MINIMUM_OPACITY))))

    log.info("behåller %d av %d gaussare", int(keep.sum()), len(model))
    return dataclasses.replace(model,
                               means=model.means[keep],
                               quats=model.quats[keep],
                               scales=model.scales[keep],
                               opacities=model.opacities[keep],
                               colors=model.colors[keep])


def synthetic_keyframes(model: SplatModel,
                        bundle: ScanBundle,
                        extra_views: int = DEFAULT_EXTRA_VIEWS) -> list[Keyframe]:
    """Renderar om rummet från de riktiga poserna plus några däremellan.

    De inskjutna vyerna är hela vinsten med att gå via en splat: de ser ytor
    som råkade hamna mellan två foton.

    Fick kamerorna glida under träningen renderas det ur de justerade poserna.
    Splatten är skarp bara sett från de poser den tränades i; ur ARKits
    ursprungliga står bilden några centimeter fel och bakningen smetar igen.
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
    for identifier, (frame, pose, exact) in enumerate(_poses(bundle, extra_views, model.poses)):
        view = _view(frame, device, camera_from_world=pose)
        with torch.no_grad():
            image, _ = _rasterize(parameters, view, device)

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


def _seed(positions: np.ndarray, normals: np.ndarray,
          max_splats: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Startpunkter ur LiDAR-ytan: platta skivor som ligger an mot väggen.

    Skalan sätts av avståndet till grannen, riktningen av ytans normal. Båda är
    kända — det är hela vinsten med att ha skannat rummet — och en optimerare som
    får börja med rätt form behöver aldrig hitta dit genom att först bli suddig.
    """
    from scipy.spatial import cKDTree

    positions, index = np.unique(positions.reshape(-1, 3), axis=0, return_index=True)
    positions = positions.astype(np.float32)
    normals = normals[index]
    if len(positions) > max_splats:
        picked = np.random.default_rng(0).choice(len(positions), max_splats, replace=False)
        positions, normals = positions[picked], normals[picked]

    # En gaussare ska täcka ungefär hålet till sin granne, annars syns nätet.
    distance, _ = cKDTree(positions).query(positions, k=2)
    spacing = np.maximum(distance[:, 1], 1e-3).astype(np.float32)

    radius = spacing[:, None] * 0.5
    scales = np.concatenate([radius, radius, radius * SEED_THICKNESS], axis=1)
    return positions, scales.astype(np.float32), _aligned(normals)


def _aligned(normals: np.ndarray) -> np.ndarray:
    """Kvaternioner som vrider den lokala z-axeln till ytans normal.

    Den tredje skalan är den tunna, så det är z som ska peka rakt ut ur väggen.
    Formen är den kortaste vridningen mellan två enhetsvektorer; den halva
    vinkeln kommer ur att kvaternionen redan är halva rotationen.
    """
    normals = normals / np.maximum(np.linalg.norm(normals, axis=1, keepdims=True), 1e-8)

    quats = np.zeros((len(normals), 4), np.float32)
    quats[:, 0] = 1.0 + normals[:, 2]
    quats[:, 1] = -normals[:, 1]
    quats[:, 2] = normals[:, 0]

    # Pekar normalen rakt nedåt är vridningen ett halvt varv och axeln obestämd.
    # Vilken axel i planet som helst duger då; formeln ovan ger noll.
    flipped = normals[:, 2] < -1 + 1e-6
    quats[flipped] = [0.0, 1.0, 0.0, 0.0]

    return (quats / np.linalg.norm(quats, axis=1, keepdims=True)).astype(np.float32)


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


def _densification(budget: int):
    """gsplats MCMC-strategi, med telefonens tak som antal.

    Standardstrategin delar och klonar tills bilden stämmer och kan inte hållas
    på ett antal — den lämnar över den frågan till exporten, som bara ser
    geometri och inte vad varje gaussare bidrog med. MCMC håller i stället
    antalet fast och flyttar de gaussare som slocknat dit felet är störst, så
    hela budgeten hela tiden ligger där bilden behöver den.
    """
    from gsplat.strategy import MCMCStrategy

    strategy = MCMCStrategy(cap_max=budget, verbose=False)
    return strategy, strategy.initialize_state()


def _nudged(viewmat, delta):
    """Kameran flyttad med en liten stelkroppsrörelse.

    Rotationen ligger som axel-vinkel och vecklas ut med Rodrigues formel. En
    matris byggd bit för bit i stället för tilldelad på plats, så gradienten
    hittar hela vägen tillbaka till ``delta``.
    """
    import torch

    rotation, translation = delta[:3], delta[3:]
    zero = torch.zeros((), device=delta.device, dtype=delta.dtype)
    skew = torch.stack([
        torch.stack([zero, -rotation[2], rotation[1]]),
        torch.stack([rotation[2], zero, -rotation[0]]),
        torch.stack([-rotation[1], rotation[0], zero]),
    ])
    # Termen är singulär i noll, och noll är precis där träningen börjar.
    angle = torch.linalg.norm(rotation) + 1e-8
    matrix = (torch.eye(3, device=delta.device, dtype=delta.dtype)
              + torch.sin(angle) / angle * skew
              + (1 - torch.cos(angle)) / angle ** 2 * (skew @ skew))

    bottom = torch.tensor([[0.0, 0.0, 0.0, 1.0]], device=delta.device, dtype=delta.dtype)
    nudge = torch.cat([torch.cat([matrix, translation[:, None]], dim=1), bottom], dim=0)
    return (nudge @ viewmat[0])[None]


def _refined(frames: list[Keyframe], views: list[dict], deltas) -> np.ndarray:
    """De justerade kamerorna tillbaka i ARKits koordinatsystem."""
    import torch

    poses = []
    for index, frame in enumerate(frames):
        with torch.no_grad():
            viewmat = _nudged(views[index]["viewmat"], deltas[index])[0].cpu().numpy()
        # `_ARKIT_TO_OPENCV` är sin egen invers, så samma matris på båda sidor.
        poses.append(_ARKIT_TO_OPENCV @ viewmat)

    # Kamerans plats i rummet, inte matrisens translationsdel: den senare är
    # −R·C och ändrar sig även när kameran bara vridit sig.
    moved = [float(np.linalg.norm(np.linalg.inv(pose)[:3, 3]
                                  - np.linalg.inv(frame.camera_from_world)[:3, 3]))
             for pose, frame in zip(poses, frames)]
    log.info("kamerorna flyttade sig %.1f mm i median, som mest %.1f mm",
             float(np.median(moved)) * 1000, float(np.max(moved)) * 1000)
    return np.stack(poses).astype(np.float32)


def _ssim(rendered, target, window: int = 11, sigma: float = 1.5):
    """Strukturlikhet mellan två bilder, 1 om de är identiska.

    Finns här för att L1 ensamt inte straffar suddighet: ett medelvärde av två
    foton som är oense ligger nära båda i pixelavstånd. SSIM jämför i stället
    lokal kontrast och samvariation, och en utsmetad vägg tappar båda.
    """
    import torch
    import torch.nn.functional as functional

    first, second = rendered.permute(2, 0, 1)[None], target.permute(2, 0, 1)[None]
    channels = first.shape[1]

    offsets = torch.arange(window, device=first.device, dtype=first.dtype) - window // 2
    weights = torch.exp(-offsets ** 2 / (2 * sigma ** 2))
    weights = weights / weights.sum()
    # Separabelt: två endimensionella svep i stället för ett 11×11-fönster.
    horizontal = weights.view(1, 1, 1, window).repeat(channels, 1, 1, 1)
    vertical = weights.view(1, 1, window, 1).repeat(channels, 1, 1, 1)

    def blur(image):
        image = functional.conv2d(image, horizontal, padding=(0, window // 2), groups=channels)
        return functional.conv2d(image, vertical, padding=(window // 2, 0), groups=channels)

    mean_first, mean_second = blur(first), blur(second)
    first_squared, second_squared = mean_first ** 2, mean_second ** 2
    crossed = mean_first * mean_second
    variance_first = blur(first * first) - first_squared
    variance_second = blur(second * second) - second_squared
    covariance = blur(first * second) - crossed

    stabiliser, contrast = 0.01 ** 2, 0.03 ** 2
    return (((2 * crossed + stabiliser) * (2 * covariance + contrast))
            / ((first_squared + second_squared + stabiliser)
               * (variance_first + variance_second + contrast))).mean()


def _rasterize(parameters: dict, view: dict, device: str, viewmat=None):
    import torch
    from gsplat import rasterization

    width, height = view["size"]
    render, _, info = rasterization(
        means=parameters["means"],
        quats=torch.nn.functional.normalize(parameters["quats"], dim=-1),
        scales=torch.exp(parameters["scales"]),
        opacities=torch.sigmoid(parameters["opacities"]),
        colors=parameters["colors"],
        viewmats=view["viewmat"] if viewmat is None else viewmat,
        Ks=view["K"],
        width=width,
        height=height,
        render_mode="RGB",
    )
    return render[0, ..., :3], info


def _poses(bundle: ScanBundle,
           extra_views: int,
           refined: np.ndarray | None = None) -> list[tuple[Keyframe, np.ndarray, bool]]:
    """De riktiga poserna, med några inskjutna emellan.

    Flaggan säger om posen är ett fotos egen. Bara då finns en uppmätt djupkarta
    som gäller för vyn.
    """
    frames = bundle.keyframes
    cameras = ([frame.camera_from_world for frame in frames] if refined is None
               else list(refined))
    poses: list[tuple[Keyframe, np.ndarray, bool]] = []

    for index, frame in enumerate(frames):
        poses.append((frame, cameras[index], True))
        if extra_views <= 0 or index + 1 >= len(frames):
            continue

        for step in range(1, extra_views + 1):
            fraction = step / (extra_views + 1)
            poses.append((frame, _between(cameras[index], cameras[index + 1], fraction), False))
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
