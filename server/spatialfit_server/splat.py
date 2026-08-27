"""Gaussian splatting som färgkälla, tränad på rummets egna foton.

Fogen mot resten av bakningen är ``Keyframe``, inte ``bake._contribution``.
En tränad splat renderar *nya* foton med kända poser, och de går rakt in i
``bake()`` utan att en rad där behöver ändras. Det ger tre saker som den råa
blandningen inte kan ge:

* hål fylls, eftersom en virtuell kamera kan ställas där ingen råkade fota,
* bruset jämnas ut, eftersom varje splat sett rummet från många håll,
* exponeringshoppen försvinner, eftersom en och samma modell renderar allt.

Detta skiljer träningen från 3DGS som det brukar se ut:

**Ingen sfärisk harmonik.** Färgen är vy-oberoende (SH-grad 0). En diffus
texturatlas kan ändå inte bära vy-beroende ljus, och med högre grad hade en
spegling från ett enda håll bakats in i väggen som en fläck.

**Tät start i LiDAR-ytans hörn**, inte glesa SfM-punkter. Men en gaussare per
hörn är ett tak på detaljnivån som ligger UNDER fotots (200 000 hörn mot foton
à 1536 px), så gsplat får ändå dela och klona där bilden inte stämmer.

**Gaussarna hålls vid den mätta ytan.** Fritt tränad lägger sig en splat som
dimma mellan kameran och väggen — det sänker pixelfelet billigare än en skarp
yta. Vanlig 3DGS har inget att sätta emot; vi har LiDAR-ytan, och
``MAXIMUM_DRIFT`` och ``MAXIMUM_RADIUS`` säger att en gaussare ska sitta på det
som mätts upp och vara stor som en bit av det.

Ytan är den *städade* (``connected_surface``) plus varje LiDAR-djuppixel
(``measured_points``). Båda leden behövs: ARKit lämnar flagor mitt i rummet där
en gaussare är lagligt placerat brus, och meshen tappar gardiner, växter och
soffkanter — där finns ingen laglig plats för det fotot ser, och färgen smetas
ut på väggen bakom som vit frost.

**De startar som skivor, inte klot.** Vi vet var ytan är och ger dem dess normal
och en tunn tredje axel. Mellersta axeln blir fjorton gånger den minsta. Mät
``max/mid`` och ``mid/min`` var för sig — ``max/min`` skiljer inte nål från skiva.

**Poserna får glida, men bara för bildens skull.** ARKits reprojektionsfel är
2–3 cm, alltså 15–20 px glidning mellan två foton av samma vägg, och en splat
tränad mot foton som är så oense blir ett suddigt medelvärde. Justeringen
stannar i träningen; det som MÄTS kommer fortfarande från ARKits egna poser.
Se ``POSE_LEARNING_RATE`` — "några millimeter" måste hållas efter.

**Fotona är inte överens om hur ljust rummet är.** ``adapt_appearance`` ger
varje foto sex tal som förklarar bort dess egen ton, så gaussarna slipper göra
det med sin färg. Se ``APPEARANCE_LEARNING_RATE``.

**Förlusten är inte bara L1.** Ett pixelavstånd är nöjt med ett medelvärde, så
``SSIM_WEIGHT`` väger in strukturlikhet, som ser skillnad på skarpt och utsmetat.

**Djupet kommer inte från splatten.** Splattens djup är ett genomsnitt över
halvgenomskinliga gaussare och blir systematiskt grundare än ytan, desto mer ju
längre träningen håller på — ett skymningstest mot det kastar bort korrekta
texlar. En vy i ett fotos pose ärver fotots LiDAR-djup; en inskjuten vy får inget.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np

from .atlas import vertex_normals
from .bundle import (Keyframe, ScanBundle, connected_surface, measured_points,
                     sharpness_weights)

log = logging.getLogger(__name__)

#: Antal gaussare att starta med.
DEFAULT_MAX_SPLATS = 300_000
#: 7 000 → 30 000 steg tar felet mot fotot från 24 till 8,7 grånivåer.
DEFAULT_ITERATIONS = 30_000
#: Hur många extra vyer som vävs in mellan de riktiga fotona.
DEFAULT_EXTRA_VIEWS = 2
#: Telefonens tak, och även träningens antal — MCMC håller det konstant.
#:
#: Skärpan avgörs av gaussare per KVADRATMETER: samma budget ger 85 % av fotots
#: skärpa på ETT hörn men 40 % på hela rummet. Budgetsvepet 220k → 455k → 771k
#: (40 → 49 → 58 %) mätte i själva verket ``MAXIMUM_RADIUS`` genom budgeten,
#: eftersom fler gaussare på samma yta tvingar fram mindre. Mätt var för sig är
#: radien allt och budgeten nästan verkningslös (``splat_check.py``):
#:
#: ==========  ==========  =======  ==========  ========
#: radietak    tjocklek    budget   gaussare      skärpa
#: ==========  ==========  =======  ==========  ========
#: 5 cm        fri            2 M     530 264    52,5 %
#: 8 mm        fri            2 M   1 729 853    70,3 %
#: 8 mm        fri            3 M   2 428 287    71,9 %
#: 6 mm        1 mm           3 M   2 786 113    86,1 %
#: 4 mm        0,8 mm         3 M   2 935 585   115,1 %
#: ==========  ==========  =======  ==========  ========
#:
#: En halv miljon extra gaussare gav 1,6 procentenheter, en fyra gånger mindre
#: radie gav arton. Budgeten är satt så att radien inte svälter: vid 6 mm blir
#: 2,79 M kvar. Tal ÖVER 100 % är sämre, inte bättre — se ``MAXIMUM_RADIUS``.
PHONE_SPLAT_BUDGET = 3_000_000

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
#: Får inte sänkas "för att skydda geometrin" — splatten mäter ingenting, och en
#: gaussare som inte får flytta sig växer i stället tills den täcker felet.
MEANS_LEARNING_RATE = 1.6e-4

#: Genomskinliga från början, annars äter den främsta hela alfat och ytorna
#: bakom får aldrig någon gradient.
INITIAL_OPACITY = 0.1

#: Kamerornas egen inlärningstakt. Adam tar ungefär ett steg av storleken ``lr``
#: oavsett gradient, så takten sätter hur långt kameran KAN gå och avklingningen
#: drar den tillbaka mot ARKits pose. Vid 1e-4 gick kamerorna 44 mm i median och
#: 179 mm som mest — mer än de 2–3 cm de skulle rätta.
POSE_LEARNING_RATE = 1e-5
POSE_DECAY = 1e-6

#: ARKits automatik justerar sig medan man går: ljusaste fotot är 2,30 gånger
#: det mörkaste, blått mot grönt svänger 0,71–1,01, och två foton i följd hoppar
#: 53 grånivåer. Det ensamt är L1 0,068 av 0,121 på undanhållna foton. Varje
#: foto får därför sex egna tal (förstärkning och nollpunkt per kanal) som lärs
#: med bilden; de kan bara förklara bort exponeringen, inte hitta på detaljer.
#: Rättelsen stannar i träningen — det som renderas ut har rummets gemensamma ton.
APPEARANCE_LEARNING_RATE = 1e-3
APPEARANCE_DECAY = 1e-6

#: Hur mycket av förlusten som är strukturlikhet i stället för pixelavstånd.
#: Samma vikt som 3DGS-artikeln använder.
SSIM_WEIGHT = 0.2

#: MCMC-strategin håller antalet gaussare konstant genom att flytta de döda dit
#: bilden är fel. Utan de här straffen driver den mot många nästan genomskinliga
#: och stora gaussare, eftersom en dimma sänker förlusten billigt. Vikten är
#: gsplats egen.
SCALE_PENALTY = 0.01

#: Hur hårt en gaussare tvingas välja mellan att täcka och att inte finnas.
#: Störst vid alfa 0,5 och noll i båda ändarna, så det säger inte vilket håll en
#: gaussare ska ta, bara att den inte får bli hängande halvvägs. Ett straff rakt
#: NEDÅT på opaciteten mättes verkningslöst (86,1 mot 86,3 %).
#:
#: Felet syns bara om man frågar renderaren: vid 6 mm täcks varje pixel av 55
#: gaussare medan medelalfat 0,30 gör att 6,4 lager räcker för att skymma. 55
#: fritt optimerade färger per pixel har oändligt många blandningar som ser lika
#: ut från träningsvyerna och skiljer sig från nya. Det är skimret.
OPACITY_POLARITY = 0.01

#: Svagare än så syns en gaussare inte. Att kasta dem halverar nästan filen,
#: kostar 0,14 dB och gör bilden marginellt SKARPARE.
MINIMUM_OPACITY = 0.05

#: Golv för opaciteten under träningen, klämt varje steg. Noll stänger av det.
#: Ett golv och inte ett startvärde, eftersom en tidig täckande gaussare stryper
#: gradienten till allt bakom — jämför ``INITIAL_OPACITY``.
#:
#: ===== ========= ====== ====== ==================
#: golv  gaussare  L1     skärpa spridning på vägg
#: ===== ========= ====== ====== ==================
#: 0     2 790 512 0,1156  89,7% 5,20×
#: 0,50  3 000 000 0,1163  98,9% 4,38×
#: 0,90  3 000 000 0,1174 103,7% 4,32×
#: ===== ========= ====== ====== ==================
#:
#: Sista kolumnen är ``tools/korn2.py``. Golvet valdes när kornet var det som
#: syntes, och kolumnen "skärpa" lästes som att 98,9 % vore bättre än 89,7 %.
#: Båda de premisserna föll: skärpetalet straffar korn och belönar sudd, så tal
#: över 100 % är SÄMRE, och kornet självt satt i ``MAXIMUM_RADIUS``. Kvar står
#: L1, som pekar åt noll. Golvet är alltså avstängt — gratis, som svepet visade.
MINIMUM_ALPHA = 0.0

#: Hur långt en gaussares kulör får avvika från sitt grannskaps. Noll stänger av.
#: Där FOTOT är jämnt ligger dess kulörspridning på 0,74 grånivåer men
#: renderingens på 4,42 — den pastellrosa fläckigheten finns alltså redan i
#: serverns rendering och är inte telefonens färgrum. Inget i förlusten säger att
#: två grannar på samma vägg ska ha samma nyans; taket säger det i stället.
#:
#: Uppmätt: kulörspridningen går 6,3 → 1,9 gånger fotots, L1 rör sig inte
#: (0,1163 mot 0,1167), och ett brunt parkettgolv som renderades GRÖNT blir
#: brunt. Ljushetsbruset stiger 4,4 → 5,0 — samma underbestämning uttryckt i
#: ljushet — men det läses som yta, medan kulört brus läses som skimmer.
#:
#: Svept senare: gränsen har ett OPTIMUM, den är inte "hårdare är bättre". Vid
#: noll lägger sig en rosa slöja över rummet, vid 0,005 är kulören stängd så
#: hårt att den kostar mer än den ger. 0,05 är botten på kurvan.
MAXIMUM_CHROMA = 0.05

#: Hur stor ruta som räknas som en gaussares grannskap när kulören kläms.
#: Vid 2 cm togs bara sex procent av felet trots att klämningen bet (spridningen
#: inom rutan föll 24,4 → 2,6). Felet är storskalig nyansdrift, inte punktbrus:
#: 28 grånivåer står MELLAN rutorna vid 2 cm och 15 återstår vid en halv meter.
#: En kvarts meter är alltså den skala felet lever på, inte ett geometriskt
#: grannskap. Riktiga färgkanter plattas inte ut — golvets gräns mot väggen står.
CHROMA_NEIGHBOURHOOD = 0.25

#: Hur långt utanför skanningens egen låda en gaussare får ligga. MCMC:s brus
#: slungar iväg ett par tusen. De är osynliga men inte gratis: telefonen ställer
#: kameran efter splattens utsträckning, och rummet mätte 1 343 m i stället för 9.
ROOM_MARGIN = 1.0

#: Största radie en gaussare får ha. **Talet som avgör skärpan.**
#:
#: Medianaxeln ljuger om huruvida taket binder — fråga renderaren i stället
#: (``info`` från ``rasterization``). Vid 5 cm projicerar medianen till 18 px
#: radie på en 1536 px bred bild och varje pixel täcks av 339 gaussare: inte en
#: yta utan trehundra halvgenomskinliga lager, och blandningen av dem ÄR diset.
#: Utan tak blev största radien 1,46 m med de tio största mitt i luften.
#:
#: Stod på 6 mm och var då det som gjorde rummet grynigt. Uppmätt svep med
#: ``kant_check.py`` och ``korn2.py``, som skiljer sudd från korn:
#:
#: ======== ========== ========== ====== ======
#: radietak kantskärpa i pixlar   korn   kulör
#: ======== ========== ========== ====== ======
#: 6 mm     0,62×      0,78 px    5,13×  1,8×
#: 20 mm    0,55×      0,93 px    5,45×
#: 60 mm    0,55×      0,93 px    4,06×
#: 1 m      0,55×      0,93 px    2,59×  1,0×
#: ======== ========== ========== ====== ======
#:
#: **Kolumnen "i pixlar" är hela poängen.** Kvoten är enhetslös och omöjlig att
#: väga mot kornet förrän den kalibrerats mot känt sudd — kör
#: ``kant_check.py <rum> --calibrate``. Att släppa taket kostar 0,15 pixlar
#: oskärpa, vilket ingen kan se, och halverar kornet samtidigt som kulören
#: landar exakt på fotots. Geometrin blir marginellt sämre (överskott mot ytan
#: 2,6 → 3,5 mm, ``skal_check.py``), fortfarande långt under en centimeter.
#:
#: Anledningen syns i axlarna: med taket på 6 mm låg MEDIANEN på 5,75 mm, alltså
#: klistrad mot gränsen — en mosaik av likstora brickor, och mosaiken var
#: kornet. Utan tak blir medianen 2,74 mm medan 99:e percentilen är 55 mm: de
#: flesta blir MINDRE, ett fåtal växer till stora plattor på de släta väggarna.
#:
#: Taket infördes när ``MAXIMUM_THICKNESS`` inte fanns och en stor gaussare
#: verkligen var en dimboll. Med tjockleken klämd är en stor gaussare i stället
#: en tunn platta som ligger an mot väggen. Rör inte det ena utan att mäta det
#: andra.
MAXIMUM_RADIUS = 1.0

#: Hur tjock en gaussare får vara tvärs sin tunnaste led.
#: ``MAXIMUM_RADIUS`` klämmer bara den STÖRSTA axeln, så allt samlas mot taket
#: och rundas av till klot (mellersta axeln 1,1 gånger den minsta). En vägg av
#: fyra millimeters klot är bucklig av sig själv — den ulliga stucco-ytan. Med
#: den här gränsen blir mellersta axeln 7,4 gånger den minsta, alltså riktiga
#: skivor, och skärpan steg 82 → 86 % vid samma radie. ``SEED_THICKNESS`` ensam
#: räcker inte: bara tak binder under träningen. Noll stänger av.
#:
#: Den där skärpehöjningen var en synvilla: talet stiger av korn lika gärna som
#: av skärpa, och 1 mm var satt när radietaket ännu gjorde rummet grynigt. Mätt
#: om med ögat och med L1 är gränsen en SUDDKÄLLA — en millimeter är tunnare än
#: hälften av det rummet faktiskt består av, och det som inte får plats i en
#: skiva blir i stället flera överlappande. Därför avstängd.
MAXIMUM_THICKNESS = 0.0

#: Hur långt från LiDAR-ytan en gaussare får driva. Utan gränsen låg 74 % av
#: gaussarna mer än 2 cm från ytan och bar 91 % av den synliga massan.
MAXIMUM_DRIFT = 0.02

#: Hur många grader sfäriska harmoniker färgen får. Noll betyder att varje
#: gaussare har EN färg, lika från alla håll — det är den sista arkitektoniska
#: skillnaden mot vanlig 3DGS, som kör grad 3.
#:
#: Grad 0 kan inte beskriva en yta som ser olika ut från olika håll: fönsterglas,
#: lackat trä, blanka vitvaror, en vägg med släpljus. Optimeraren kan bara svara
#: på den motsägelsen med att smeta ut GEOMETRIN tills medelvärdet stämmer
#: någorlunda från alla håll, och det syns som grov mjukhet i mellanskalan —
#: precis det fel som är kvar när klämmorna är avfärdade.
#:
#: Mätt: L1 14,75 → 10,99, korn 2,34× → 1,53×, kant 0,22× → 0,27×. Alla tre åt
#: samma håll, alltså en saknad frihetsgrad snarare än en avvägning.
#:
#: Priset är bandbredd, men mycket mindre än befarat: 45 extra tal per gaussare
#: blir 60,7 MB mot 32,8 för 1,9 M gaussare, inte de 195 MB som stod här förr.
#: Kvantiseringen lägger de flesta banden nära noll och gzip äter dem.
#:
#: Var noll ända tills 2026-08-26, då `write_spz` lärde sig skriva banden. Innan
#: dess KASTADES de vid exporten, och det var slöjan i appen — nolltermen ensam
#: är en rest, inte en fristående färg.
SPHERICAL_HARMONICS = 3

#: Hur mycket långsammare de högre graderna lär sig än grundfärgen. Talet är
#: 3DGS eget. Utan det skenar de: med grundfärgens takt låg förlusten på 0,25
#: mot 0,10 vid steg 6 000 och 2,9 av 3 miljoner gaussare klämdes mot ytan varje
#: steg — lägena jagade en färg som inte stod stilla.
SH_RATE_DIVISOR = 20

#: Hur ofta varje gaussare får leta upp sin ytpunkt på nytt. Klämningen sker
#: VARJE steg — se ``_pulled_to_surface``; bara KD-trädsfrågan är dyr. Låg på
#: 250, men det motiverades av gradientsteg och MCMC skakar lägena med brus: en
#: slumpvandring når √250 gånger så långt. Då rycktes 78 % av budgeten tillbaka
#: flera centimeter vid steg 5 500, och de flesta slocknade av det.
SURFACE_INTERVAL = 100

#: Om förtätningen ska styras av GRADIENTEN i stället för av opaciteten.
#:
#: MCMC håller antalet gaussare fast och flyttar de slocknade dit felet är
#: störst. Den har därför ingen gradientstyrd förtätning alls: fördelningen
#: följer opacitet mot ett tak, inte var bilden är fel. ``DefaultStrategy`` —
#: som Inrias original, gsplats eget förval och nerfstudios ``splatfacto``
#: använder — klonar och delar där skärmgradienten är stor, alltså vid kanterna.
#:
#: MÄTT UTAN VINST: kantskärpa 0,63× mot MCMC:s 0,62× och korn 5,76× mot 5,13×,
#: alltså likvärdig på kanterna och sämre på ytorna. Hypotesen var att MCMC:s
#: enda storlekstak för allt hindrade små gaussare vid kanten och stora på
#: väggen samtidigt; den adaptiviteten kom i stället ur att släppa
#: ``MAXIMUM_RADIUS``. Koden står kvar avstängd för att svaret ska gå att
#: kontrollera utan att byggas om.
#:
#: Antalet gaussare blir inte längre exakt ``PHONE_SPLAT_BUDGET`` (vi fick
#: 1,85 M), så exporten kan behöva gallra — kontrollera talet i loggen.
GRADIENT_DENSIFICATION = False

#: Skärmgradient över vilken en gaussare klonas eller delas. gsplats förval är
#: 0,0002 för ``absgrad=False``; med ``absgrad=True``, som är det som mäter var
#: bilden faktiskt är fel, är 0,0008 gsplats eget rekommenderade tal.
GROW_GRADIENT = 0.0008

#: Andel av träningen som får förtäta. Sista fjärdedelen ska bara finslipa —
#: nya gaussare där hinner ändå inte lära sig sin färg.
REFINE_STOP = 0.75

#: Hur ofta opaciteten nollställs mot ett lågt värde. Det är greppet som gör att
#: dimma inte kan överleva: alla tvingas ned och bara de som verkligen behövs
#: tar sig upp igen. MCMC har ingen motsvarighet.
OPACITY_RESET = 3000

#: Hur tunn en startgaussare är tvärs ytan, som andel av avståndet till grannen.
#: Utan startriktning var hälften av de tränade gaussarna närmast klotformade
#: (mellersta axeln 1,45 gånger den minsta), alltså hittade optimeraren aldrig dit.
SEED_THICKNESS = 0.1

#: Låt skarpa foton väga tyngre än suddiga (``bundle.sharpness_weights``).
#: Träningen tror annars lika mycket på ett foto taget mitt i en sväng som på
#: ett stillastående, och lär sig att tavelramar ÄR smetar. Mätt på rummet: L1
#: 11,96 → 10,41, korn 1,39× → 1,19×, kant 0,53× → 0,58× — alla tre åt samma
#: håll, alltså ingen avvägning. Vikterna spänner bara 0,30–1,12; det är ett
#: milt ingrepp, för GALLRING av de suddiga knäcker geometrin (suddet klumpar
#: sig i tid, så en skur ÄR en hel vy).
WEIGH_SHARPNESS = True


def train(bundle: ScanBundle,
          iterations: int = DEFAULT_ITERATIONS,
          max_splats: int = DEFAULT_MAX_SPLATS,
          densify: bool = True,
          refine_poses: bool = True,
          adapt_appearance: bool = True,
          budget: int = PHONE_SPLAT_BUDGET,
          pose_learning_rate: float = POSE_LEARNING_RATE,
          minimum_alpha: float = MINIMUM_ALPHA,
          maximum_chroma: float = MAXIMUM_CHROMA,
          maximum_drift: float = MAXIMUM_DRIFT,
          maximum_thickness: float = MAXIMUM_THICKNESS,
          sh_degree: int = SPHERICAL_HARMONICS,
          gradient_densification: bool = GRADIENT_DENSIFICATION,
          weigh_sharpness: bool = WEIGH_SHARPNESS) -> SplatModel:
    """Passar gaussare mot fotona. Kräver CUDA.

    ``budget`` är telefonens tak och gäller redan här, genom MCMC-strategin.
    Att låta exporten gallra efteråt gick inte: den mätte opacitet gånger volym
    och valde alltså de STÖRSTA — en skarp skiva har liten volym, en smetig
    klump stor — så hälften av den exporterade miljonen var närmast klot.
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
        # håll oavsett rummets ton. Vid grad 0 är färgen RGB rakt av; över noll
        # är den SH-nolltermen, och gsplat lägger självt på 0,5 efter att ha
        # summerat koefficienterna — då är noll samma grå.
        "colors": torch.nn.Parameter(
            torch.full((len(means), 3), 0.5, device=device) if sh_degree == 0
            else torch.zeros((len(means), 1, 3), device=device)),
    })
    if sh_degree:
        # De högre graderna är en EGEN parameter, inte fler kolumner i den förra.
        # De måste gå långsammare — 3DGS ger dem en tjugondel av grundfärgens
        # takt — och gsplat kan bara ge olika takt åt olika parametrar. Med samma
        # takt som grundfärgen skenar de: förlusten låg på 0,25 mot 0,10 vid steg
        # 6 000 och 2,9 av 3 miljoner gaussare klämdes mot ytan varje steg,
        # eftersom lägena jagade en färg som inte stod stilla.
        parameters["sh"] = torch.nn.Parameter(
            torch.zeros((len(means), (sh_degree + 1) ** 2 - 1, 3), device=device))
    # gsplats förtätningsstrategi flyttar rader i både parametrar och Adams
    # tillstånd, och kan bara göra det när varje parameter har en egen
    # optimerare. Därför en per namn i stället för en med fem grupper.
    scene_scale = max(float(np.linalg.norm(means.max(axis=0) - means.min(axis=0)) / 2), 1e-3)
    rates = dict(LEARNING_RATES, means=MEANS_LEARNING_RATE * scene_scale)
    if sh_degree:
        rates["sh"] = LEARNING_RATES["colors"] / SH_RATE_DIVISOR
    optimizers = {name: torch.optim.Adam([{"params": parameters[name], "lr": rate, "name": name}])
                  for name, rate in rates.items()}

    # Takten för lägena trappas ned hundrafalt över träningen. Utan det fortsätter
    # gaussarna att skaka i sista steget lika mycket som i första, och en yta som
    # aldrig får stanna hinner aldrig bli skarp.
    schedule = torch.optim.lr_scheduler.ExponentialLR(
        optimizers["means"], gamma=0.01 ** (1.0 / max(iterations, 1)))

    strategy, state = (_densification(budget, iterations, gradient_densification)
                       if densify else (None, None))
    gradient_driven = strategy is not None and hasattr(strategy, "grow_grad2d")

    # Hela ytan, inte de utglesade startpunkterna, och inte bara meshens punkter
    # utan varje LiDAR-djuppixel: meshen tappar gardiner, växter och soffkanter,
    # så 9 % av rutorna LiDAR såg saknade yta i den och renderingsfelet var 2,4
    # gånger högre just där. Det var den vita frosten. Med djupkartorna faller
    # andelen till 2,8 %. Sådden är kvar på meshen, som är det enda med normaler.
    anchor_cloud = np.concatenate(
        [surface, measured_points(bundle.keyframes)]).astype(np.float32)
    log.info("ankarmoln: %d punkter, varav %d ur djupkartorna",
             len(anchor_cloud), len(anchor_cloud) - len(surface))
    tree = cKDTree(anchor_cloud)
    anchor_points = torch.tensor(anchor_cloud, device=device)
    anchors = None
    neighbourhood = None

    views = [_view(frame, device) for frame in frames]
    generator = np.random.default_rng(0)

    weights = np.ones(len(views))
    if weigh_sharpness:
        weights = sharpness_weights(frames)
        log.info("fotovikter: %.2f som lägst, %.2f som högst, %d under halva",
                 weights.min(), weights.max(), int((weights < 0.5).sum()))

    # Kamerajusteringen hålls utanför `optimizers`: den ordboken tillhör
    # förtätningsstrategin, som förutsätter att varje post är en gaussarlista.
    deltas = None
    pose_optimizer = None
    if refine_poses:
        deltas = torch.nn.Parameter(torch.zeros(len(views), 6, device=device))
        pose_optimizer = torch.optim.Adam([deltas], lr=pose_learning_rate,
                                          weight_decay=POSE_DECAY)

    # Log-förstärkning och nollpunkt per kanal och foto. Noll i båda är ett
    # oförändrat foto, vilket är där de börjar.
    appearance = None
    appearance_optimizer = None
    if adapt_appearance:
        appearance = torch.nn.Parameter(torch.zeros(len(views), 6, device=device))
        appearance_optimizer = torch.optim.Adam([appearance], lr=APPEARANCE_LEARNING_RATE,
                                                weight_decay=APPEARANCE_DECAY)

    for step in range(iterations):
        index = int(generator.integers(len(views)))
        view = views[index]
        viewmat = view["viewmat"] if deltas is None else _nudged(view["viewmat"], deltas[index])
        rendered, info = _rasterize(parameters, view, device, viewmat,
                                    absgrad=gradient_driven)
        if appearance is not None:
            # Minus medelvärdet: bara SKILLNADER i ton får uttryckas, aldrig en
            # gemensam förskjutning. Annars är parametriseringen tvetydig —
            # modellen kan bli mörkare medan alla rättelser blir ljusare, till
            # samma förlust. Utan ankaret växte felet mot ett foto rakt av från
            # 0,121 till 0,137 fast rummet blev bättre.
            rendered = _exposed(rendered, appearance[index] - appearance.mean(dim=0))

        target = view["image"].float() / 255.0
        # Bara den fotometriska delen viktas. Straffen nedan är villkor på
        # modellen själv och har inget med fotot att göra.
        loss = weights[index] * ((1 - SSIM_WEIGHT) * (rendered - target).abs().mean()
                                 + SSIM_WEIGHT * (1 - _ssim(rendered, target)))
        if strategy is not None and not gradient_driven:
            # Med ett fast antal gaussare är det billigt att lägga sig som dimma
            # över hela rummet: många halvgenomskinliga klumpar sänker
            # pixelfelet utan att någon yta blir skarp. Straffen gör dimman dyr,
            # så budgeten går till täta gaussare som sitter på en yta.
            # Standardstrategin gallrar bort dimman i stället och behöver dem inte.
            alpha = torch.sigmoid(parameters["opacities"])
            loss = (loss
                    # Fyran gör att termen är ett vid alfa 0,5 och noll i ändarna.
                    + OPACITY_POLARITY * (4 * alpha * (1 - alpha)).mean()
                    + SCALE_PENALTY * torch.exp(parameters["scales"]).abs().mean())

        for optimizer in optimizers.values():
            optimizer.zero_grad(set_to_none=True)
        if pose_optimizer is not None:
            pose_optimizer.zero_grad(set_to_none=True)
        if appearance_optimizer is not None:
            appearance_optimizer.zero_grad(set_to_none=True)
        if gradient_driven:
            # Sparar gradienten på skärmlägena. Utan det här anropet finns inget
            # att förtäta efter — ``means2d.grad`` är en mellanled och kastas.
            strategy.step_pre_backward(params=parameters, optimizers=optimizers,
                                       state=state, step=step, info=info)
        loss.backward()

        for optimizer in optimizers.values():
            optimizer.step()
        if pose_optimizer is not None:
            pose_optimizer.step()
        if appearance_optimizer is not None:
            appearance_optimizer.step()

        if gradient_driven:
            strategy.step_post_backward(params=parameters, optimizers=optimizers,
                                        state=state, step=step, info=info)
        elif strategy is not None:
            # MCMC:s brus som flyttar de slocknade gaussarna skalas med lägenas
            # inlärningstakt, och den trappas ned. Sent i träningen ska en
            # gaussare som hittat sin plats stå still.
            strategy.step_post_backward(params=parameters, optimizers=optimizers,
                                        state=state, step=step, info=info,
                                        lr=schedule.get_last_lr()[0])
        schedule.step()

        with torch.no_grad():
            # Vid grad 0 ÄR färgen RGB och taket är [0, 1]. Över noll är bara
            # nolltermen en färg, och de högre graderna ska vara fria — det är i
            # dem vinkelberoendet bor. Att klämma dem vore att stänga av det man
            # just slagit på.
            if sh_degree == 0:
                parameters["colors"].clamp_(0.0, 1.0)
            else:
                parameters["colors"][:, 0].clamp_(-0.5 / SH_DC, 0.5 / SH_DC)
            parameters["scales"].clamp_(max=float(np.log(MAXIMUM_RADIUS)))
            # Och den tunnaste leden för sig, annars blir gaussaren ett klot mot
            # radietaket. Vilken av de tre axlarna som är tunnast bestäms av
            # kvaternionen och byts under träningen, så den måste letas upp varje
            # gång i stället för att pekas ut en gång för alla.
            if maximum_thickness > 0:
                thinnest = parameters["scales"].argmin(dim=1, keepdim=True)
                parameters["scales"].scatter_(
                    1, thinnest, parameters["scales"].gather(1, thinnest)
                    .clamp(max=float(np.log(maximum_thickness))))
            # Golvet är MCMC:s. Standardstrategin nollställer opaciteten med
            # jämna mellanrum för att låta dimman dö, och ett golv som klämmer
            # varje steg gör den nollställningen verkningslös — då gallras aldrig
            # någon gaussare bort och hela mekanismen är satt ur spel.
            if minimum_alpha > 0 and not gradient_driven:
                parameters["opacities"].clamp_(
                    min=float(np.log(minimum_alpha / (1 - minimum_alpha))))

            means = parameters["means"]
            if maximum_chroma > 0:
                # Rutnätet räknas om lika sällan som ytankarna: gaussarna rör sig
                # bråkdelar av en rutstorlek mellan två omräkningar.
                if neighbourhood is None or len(neighbourhood) != len(means) \
                        or step % SURFACE_INTERVAL == 0:
                    neighbourhood = _neighbourhoods(means, CHROMA_NEIGHBOURHOOD)
                if sh_degree == 0:
                    _limit_chroma(parameters["colors"], neighbourhood, maximum_chroma)
                else:
                    # ``maximum_chroma`` är mätt i RGB, så nolltermen måste dit
                    # och tillbaka. De högre graderna lämnas: kulörbruset som
                    # klämman finns för sitter i grundfärgen.
                    base = parameters["colors"][:, 0] * SH_DC + 0.5
                    _limit_chroma(base, neighbourhood, maximum_chroma)
                    parameters["colors"][:, 0] = (base - 0.5) / SH_DC
            # Ankarna letas upp på nytt när de blivit fel: strategin flyttar de
            # slocknade gaussarna och lägger till nya, och en gaussare som
            # teleporterats hör inte längre till den ytpunkt den hörde till förut.
            if (anchors is None or len(anchors) != len(means)
                    or step % SURFACE_INTERVAL == 0):
                _, nearest = tree.query(means.detach().cpu().numpy(), k=1, workers=-1)
                anchors = anchor_points[torch.as_tensor(nearest, device=device)]
            moved, pulled = _pulled_to_surface(means, anchors, maximum_drift)
            if pulled:
                means.copy_(moved)

        if step % 500 == 0:
            # Sista talet är hur många som klämdes i DET steget, inte sedan
            # sist. Ett litet tal betyder att gränsen håller löpande; ett stort
            # att gaussarna hinner fara iväg mellan klämningarna.
            log.info("steg %d/%d, förlust %.4f, %d gaussare, %d klämda",
                     step, iterations, float(loss.detach()),
                     len(parameters["means"]), pulled)

    if appearance is not None:
        centred = appearance.detach() - appearance.detach().mean(dim=0)
        gains = torch.exp(centred[:, :3]).cpu().numpy()
        log.info("exponeringsrättelsen spänner %.2f–%.2f gånger, "
                 "vitbalansen %.2f–%.2f i blått mot grönt",
                 float(gains.mean(axis=1).min()), float(gains.mean(axis=1).max()),
                 float((gains[:, 2] / gains[:, 1]).min()),
                 float((gains[:, 2] / gains[:, 1]).max()))

    # Modellen bär de sfäriska harmonikerna hopfogade; att de tränats som två
    # parametrar är en fråga om inlärningstakt och angår ingen efteråt.
    colors = parameters["colors"]
    if "sh" in parameters:
        colors = torch.cat([colors, parameters["sh"]], dim=1)

    model = SplatModel(
        means=parameters["means"].detach().cpu().numpy(),
        quats=parameters["quats"].detach().cpu().numpy(),
        scales=parameters["scales"].detach().cpu().numpy(),
        opacities=parameters["opacities"].detach().cpu().numpy(),
        colors=colors.detach().cpu().numpy(),
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
    # Är färgen sfäriska harmoniker ligger nolltermen först och resten efter, och
    # formatet vill ha dem kanalvis: alla röda koefficienter, alla gröna, alla
    # blå. Vid grad 0 blir listan tom och filen exakt densamma som förut.
    rest = model.colors.shape[1] - 1 if model.colors.ndim == 3 else 0
    fields = (["x", "y", "z", "nx", "ny", "nz"]
              + [f"f_dc_{channel}" for channel in range(3)]
              + [f"f_rest_{index}" for index in range(rest * 3)]
              + ["opacity"]
              + [f"scale_{axis}" for axis in range(3)]
              + [f"rot_{component}" for component in range(4)])

    order = np.random.default_rng(0).permutation(count)
    colors = model.colors[order]
    table = np.zeros((count, len(fields)), np.float32)
    table[:, 0:3] = model.means[order]
    # Normalerna används inte av någon visare men hör till formatet.
    if rest:
        table[:, 6:9] = colors[:, 0]
        table[:, 9:9 + rest * 3] = colors[:, 1:].transpose(0, 2, 1).reshape(count, -1)
    else:
        table[:, 6:9] = (colors - 0.5) / SH_DC
    table[:, 9 + rest * 3] = model.opacities[order]
    table[:, 10 + rest * 3:13 + rest * 3] = model.scales[order]
    table[:, 13 + rest * 3:17 + rest * 3] = model.quats[order]

    header = "\n".join(["ply", "format binary_little_endian 1.0",
                        f"element vertex {count}"]
                       + [f"property float {name}" for name in fields]
                       + ["end_header", ""])

    with Path(path).open("wb") as file:
        file.write(header.encode("ascii"))
        file.write(table.tobytes())
    log.info("skrev %d gaussare till %s", count, path)


#: Positionens upplösning i SPZ: antal bitar under decimalkommat av ett
#: 24-bitars heltal. Tolv ger 1/4096 m ≈ 0,24 mm och räcker till ±2048 m —
#: långt under både LiDAR-brus och det minsta en gaussare kan vara.
_SPZ_FRACTIONAL_BITS = 12
#: Formatets egen skalning av SH-nollterm innan den kvantiseras till en byte.
#: Fast tal i Niantics format, inte något att ställa in.
_SPZ_COLOR_SCALE = 0.15

#: Teckenbyte per SH-koefficient när y och z byter tecken, som läget gör. Banden
#: är udda och jämna funktioner av riktningen, så bara vissa vänder. Talen är
#: ``coordinateConverter`` ur `spz-swift` utvärderad med x=1, y=−1, z=−1; det är
#: samma byte som ``flip`` nedan gör på läge och kvaternion.
_SPZ_SH_FLIP = np.array([-1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0,
                         -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0])

#: Bitar per SH-koefficient: fem för grad 1, fyra för resten. Formatets eget val
#: — de första banden bär mest energi och tål minst kvantisering.
_SPZ_SH_BITS = np.array([5] * 3 + [4] * 12)


def write_spz(model: SplatModel, path) -> None:
    """Skriver splatten i Niantics SPZ-format, gzippat.

    Tjugo byte per gaussare mot PLY-formatets sextioåtta. Det är inte en
    optimering utan det som gör budgeten möjlig: skärpan sitter i gaussare per
    kvadratmeter (se ``PHONE_SPLAT_BUDGET``), och en nedladdning som telefonen
    orkar med rymmer tre gånger fler i det här formatet.

    Kvantiseringen är grov med flit och kostar mindre än den ser ut att göra:
    färgen får ungefär två grånivåer av 255, medan felet mot fotot ligger på
    tjugoåtta. Positionen är däremot nästan exakt — 0,24 mm.

    Version 3 av formatet, alltså kvaternionen som "minsta tre" (se
    ``_smallest_three``). Version 2 lagrar i stället de tre FÖRSTA talen och
    räknar fram det fjärde ur normen, och det är mätt otillräckligt: när det
    fjärde talet är litet blir det känsligt för kvantiseringsfelet i de tre
    andra, och värsta gaussaren kom 6,8° fel. Med minsta tre kostar det en byte
    till per gaussare och felet ligger på en tiondels grad.

    Läsaren (MetalSplatter) tolkar filen som "höger, upp, bak" och räknar om
    till PLY-konventionen "höger, ned, fram" genom att byta tecken på y och z.
    Vår PLY skrivs redan i ARKits system och läses utan omräkning, så här måste
    samma teckenbyte göras i förväg för att de två filerna ska visa samma rum.
    Teckenbytet gäller ÄVEN SH-banden, men inte alla lika (``_SPZ_SH_FLIP``).

    Sfäriska harmoniker skrivs om modellen har dem. Det gjorde formatet inte
    förr, och det var slöjans verkliga orsak: telefonen fick en modell vars
    optimerare hade lagt glas, lack och släpljus i band som sedan kastades.
    MetalSplatter renderar grad 0–3 sedan 1.0.1 hela vägen ned i shadern.

    Ordningen slumpas av samma skäl som i ``write_ply``.
    """
    import gzip
    import struct
    from pathlib import Path

    count = len(model.means)
    order = np.random.default_rng(0).permutation(count)

    # Höger-upp-bak in, höger-ned-fram ut: läsaren byter tecken på y och z i
    # både läge och kvaternionens tre första tal, så vi byter dem här.
    flip = np.array([1.0, -1.0, -1.0], np.float64)

    fixed = np.rint(model.means[order].astype(np.float64) * flip
                    * (1 << _SPZ_FRACTIONAL_BITS)).astype(np.int32)
    positions = ((fixed.reshape(-1, 1) >> np.array([0, 8, 16])) & 0xFF).astype(np.uint8)

    # Aldrig 0 eller 255: läsaren tar logit av talet, och båda ändarna är
    # oändligheter som förgiftar varje gaussare de rör vid.
    alphas = _to_byte(1 / (1 + np.exp(-model.opacities[order])) * 255).clip(1, 254)

    # Är modellen SH-tränad ligger nolltermen först och banden efter. Banden
    # SKA med: de bär glas, lack och släpljus, och utan dem är nolltermen en
    # rest som aldrig var tänkt att stå ensam — mätt som en slöja över hela
    # rummet (L1 25,90 mot 29,88, inbördes skillnad 19,16).
    # Formen avgör, inte antalet band: en modell tränad med grad 0 har ändå
    # koefficientaxeln kvar, och då ska nolltermen räknas om till färg precis
    # som annars — men ingen SH-sektion skrivas.
    harmonics = model.colors[order]
    spherical = harmonics.ndim == 3
    bands = harmonics.shape[1] - 1 if spherical else 0
    base = harmonics[:, 0] * SH_DC + 0.5 if spherical else harmonics

    colors = _to_byte(((base - 0.5) / SH_DC * _SPZ_COLOR_SCALE + 0.5) * 255)
    scales = _to_byte((model.scales[order] + 10) * 16)

    # wxyz hos oss, xyzw i formatet, och teckenbytet på xyz på köpet.
    quats = model.quats[order][:, [1, 2, 3, 0]].astype(np.float64) * [*flip, 1.0]
    rotations = _smallest_three(
        quats / np.maximum(np.linalg.norm(quats, axis=1, keepdims=True), 1e-12))

    parts = [positions, alphas, colors, scales, rotations]
    if bands:
        parts.append(_spz_spherical_harmonics(harmonics[:, 1:]))

    # Graden ur antalet band: (grad + 1)² koefficienter, nolltermen borträknad.
    degree = round((bands + 1) ** 0.5) - 1
    header = struct.pack("<IIIBBBB", 0x5053474E, 3, count, degree,
                         _SPZ_FRACTIONAL_BITS, 0, 0)
    body = b"".join(part.tobytes() for part in parts)
    Path(path).write_bytes(gzip.compress(header + body, 6))
    log.info("skrev %d gaussare till %s", count, path)


def _spz_spherical_harmonics(coefficients: np.ndarray) -> np.ndarray:
    """De högre SH-banden, ett byte per koefficient.

    ``coefficients`` är (gaussare, band, kanal) UTAN nolltermen. Formatet vill ha
    dem bandvis med de tre kanalerna intill varandra, vilket redan är
    minnesordningen — därför räcker en ``reshape``.

    Kvantiseringen är formatets egen: talet skalas med 128, förskjuts till mitten
    av ett byte och avrundas sedan till närmaste hink. Hinken är större för de
    högre banden, som bär mindre energi.
    """
    count, bands = coefficients.shape[:2]
    flipped = coefficients * _SPZ_SH_FLIP[:bands, None]
    buckets = (1 << (8 - _SPZ_SH_BITS[:bands]))[None, :, None]

    quantised = np.rint(flipped.astype(np.float64) * 128.0).astype(np.int32) + 128
    quantised = (quantised + buckets // 2) // buckets * buckets
    return quantised.clip(0, 255).astype(np.uint8).reshape(count, -1)


def _to_byte(values: np.ndarray) -> np.ndarray:
    """Avrundat och klippt till ett osignerat byte."""
    return np.rint(values).clip(0, 255).astype(np.uint8)


def _smallest_three(quats: np.ndarray) -> np.ndarray:
    """Kvaternioner (xyzw, normerade) packade fyra byte styck som "minsta tre".

    Det största talet lagras inte alls utan räknas fram ur normen på andra
    sidan; bara vilket av de fyra det var. Det gör felet jämnt fördelat, för
    talet som gissas är alltid det som tål gissningen bäst — till skillnad från
    version 2, som alltid utelämnar w oavsett hur litet w råkar vara.

    Trettio bitar av ordet är de tre kvarvarande talen med tio bitar var: en
    teckenbit och nio bitars belopp mot ``sqrt(1/2)``, vilket är det största ett
    icke-största tal kan vara. De två översta bitarna säger vilket som utelämnas.
    Tecknen är relativa det utelämnade talets, som därmed antas positivt — en
    kvaternion och dess negation är samma vridning.
    """
    largest = np.abs(quats).argmax(axis=1)
    rows = np.arange(len(quats))
    # Vänds så att det utelämnade talet är positivt; annars går det inte att
    # räkna fram ur normen, som saknar tecken.
    quats = np.where(quats[rows, largest][:, None] < 0, -quats, quats)

    word = largest.astype(np.uint32)
    for index in range(4):
        # Det utelämnade talet hoppas över genom att bara de andra tre skiftas
        # in; masken är noll på just den raden och lämnar ordet orört.
        keep = (largest != index)
        value = quats[:, index]
        magnitude = np.rint(np.abs(value) / np.sqrt(0.5) * 511).clip(0, 511)
        packed = (value < 0).astype(np.uint32) << 9 | magnitude.astype(np.uint32)
        word = np.where(keep, word << np.uint32(10) | packed, word)

    return ((word[:, None] >> np.array([0, 8, 16, 24], np.uint32))
            & np.uint32(0xFF)).astype(np.uint8)


def _pulled_to_surface(points, anchors, radius: float = MAXIMUM_DRIFT):
    """De gaussare som drivit för långt från sin ytpunkt, dragna tillbaka.

    ``anchors`` är den mätta ytpunkt varje gaussare hör till, en per rad. Att
    skicka in den i stället för att fråga ett KD-träd här inne är hela poängen:
    frågan kostar en halv sekund för hela budgeten och kan bara ställas några
    hundra gånger, medan klämningen är ren aritmetik och kan göras varje steg.
    Och den MÅSTE göras varje steg — MCMC skakar lägena med ett brus som över
    tvåhundrafemtio steg summerar till flera centimeter, långt utanför gränsen.

    Dras till skalet ``radius`` från ytan och inte hela vägen ned på den:
    riktningen den drev åt är oftast rätt — det är avståndet som är fel — och en
    gaussare som slängs ned på ytan varje gång tappar det den lärt sig.

    Att göra det här i stället för att straffa avståndet i förlusten är ett val:
    ytan är *mätt*, inte gissad, så det finns inget att väga den mot.

    Skriven med de operationer numpy och torch har gemensamma, så samma rader
    körs på kortet i träningen och mot en handräknad yta i testerna.
    """
    outward = points - anchors
    # Golvet är där för att en gaussare som ligger exakt på sitt ankare ska ge
    # kvoten oändligt och inte noll delat med noll. Den klipps ändå till ett.
    distance = ((outward * outward).sum(-1) ** 0.5).clip(1e-12, None)
    shrink = (radius / distance).clip(None, 1.0)
    return anchors + outward * shrink[..., None], int((shrink < 1.0).sum())


def _neighbourhoods(points, size: float):
    """Vilken rutnätsruta varje gaussare hör till, som radnummer.

    Grannskapet behövs bara för att kunna fråga vad omgivningen har för kulör,
    och ett rutnät räcker till det: två gaussare som hamnar i samma ruta sitter
    säkert nära varandra. Ett KD-träd skulle ge sannare grannar men kostar en
    halv sekund per fråga för hela budgeten, medan det här är en avrundning.

    Att rutorna är godtyckligt lagda gör inget: taket gäller mot rutans
    medelvärde, och en gaussare som råkar hamna vid en rutkant jämförs mot en
    något annan omgivning än sin närmaste. Bruset det ger är slumpmässigt och
    försvinner över de hundratals gånger rutnätet läggs om under träningen.
    """
    import torch

    keys = torch.floor(points.detach() / size).to(torch.int64)
    return torch.unique(keys, dim=0, return_inverse=True)[1]


def _limit_chroma(colors, neighbourhood, maximum: float) -> None:
    """Klämmer varje gaussares kulör mot sitt grannskaps, på plats.

    Ljusheten lämnas fri. Riktig yta har detalj i ljushet — skarvar, skuggor,
    fogar — men nästan aldrig i kulör över någon centimeter; det är samma
    egenskap som gör att JPEG kan halvera färgupplösningen utan att någon ser
    det. Gaussarnas färg är däremot tre fria tal, så bruset i dem blir kulört,
    och en grå vägg uppmättes sex gånger så färgstark som fotots.

    Kulören uttrycks som avstånd från den gröna kanalen, eftersom grönt bär det
    mesta av ljusheten. Bara rött och blått ändras, alltså rörs inte ljusheten.
    """
    import torch

    groups = int(neighbourhood.max()) + 1
    chroma = torch.stack([colors[:, 0] - colors[:, 1], colors[:, 2] - colors[:, 1]], dim=1)

    total = torch.zeros((groups, 2), device=colors.device, dtype=colors.dtype)
    total.index_add_(0, neighbourhood, chroma)
    count = torch.zeros(groups, device=colors.device, dtype=colors.dtype)
    count.index_add_(0, neighbourhood, torch.ones_like(neighbourhood, dtype=colors.dtype))
    average = (total / count[:, None])[neighbourhood]

    limited = average + (chroma - average).clamp(-maximum, maximum)
    colors[:, 0] = colors[:, 1] + limited[:, 0]
    colors[:, 2] = colors[:, 1] + limited[:, 1]
    colors.clamp_(0.0, 1.0)


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

    inside = np.all((model.means >= low) & (model.means <= high), axis=1)
    visible = model.opacities >= np.log(MINIMUM_OPACITY / (1 - MINIMUM_OPACITY))
    keep = inside & visible

    # Vilket villkor som band, och hur nära golvet de svaga låg. Skillnaden
    # avgör vad ett höjt tak är värt: ligger de strax under MINIMUM_OPACITY
    # kastas en modell som träningen räknade med, medan opacitet nära noll
    # betyder att ytan är mättad och att taket inte längre binder.
    alpha = 1 / (1 + np.exp(-model.opacities))
    log.info("behåller %d av %d gaussare (%d utanför rummet, %d för svaga)",
             int(keep.sum()), len(model), int((~inside).sum()), int((~visible).sum()))
    weak = alpha[~visible]
    if len(weak):
        log.info("de svagas opacitet: median %.4f, 90:e percentilen %.4f, "
                 "%.1f %% över halva golvet",
                 float(np.median(weak)), float(np.percentile(weak, 90)),
                 100 * float((weak > MINIMUM_OPACITY / 2).mean()))
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
        # Rå uint8 på kortet, omräknat till float först i det steg som råkar
        # dra fotot. Alla foton ligger uppe samtidigt, så vid 300 keyframes är
        # skillnaden 6,4 mot 1,6 GB — och omräkningen är gratis mot
        # rasteriseringen.
        "image": torch.tensor(frame.image, device=device),
        "intrinsics": intrinsics,
        "size": (width, height),
    }


def _densification(budget: int, iterations: int,
                   gradient_driven: bool = GRADIENT_DENSIFICATION):
    """Hur gaussarna förtätas. Returnerar strategin och dess tillstånd.

    MCMC håller antalet fast vid ``budget`` och flyttar de gaussare som slocknat
    dit felet är störst, så hela budgeten hela tiden ligger där bilden behöver
    den. Standardstrategin kan inte hållas på ett antal, men den är den ENDA av
    de två som förtätar efter var bildfelet sitter — se ``GRADIENT_DENSIFICATION``.

    De två har olika krav på anropskoden: ``DefaultStrategy`` behöver ett
    ``step_pre_backward`` för att spara gradienten på ``means2d``, och dess
    ``step_post_backward`` tar ingen inlärningstakt. Träningen frågar därför
    ``isinstance`` i stället för att gissa.
    """
    from gsplat.strategy import DefaultStrategy, MCMCStrategy

    if gradient_driven:
        strategy = DefaultStrategy(
            grow_grad2d=GROW_GRADIENT,
            refine_stop_iter=int(iterations * REFINE_STOP),
            reset_every=OPACITY_RESET,
            absgrad=True,
            verbose=False)
    else:
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


def _exposed(image, terms):
    """Bilden sedd genom ett visst fotos exponering och vitbalans.

    Förstärkningen ligger som logaritm så att den är symmetrisk kring
    oförändrat och aldrig kan bli negativ. Ingen klippning: målet ligger i
    [0, 1] och förlusten håller kvar bilden där ändå, medan en klippning hade
    dödat gradienten precis i de överexponerade fönster där rättelsen behövs.
    """
    import torch

    return image * torch.exp(terms[:3]) + terms[3:]


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


def _rasterize(parameters: dict, view: dict, device: str, viewmat=None,
               absgrad: bool = False):
    """Renderar vyn.

    ``absgrad`` måste begäras HÄR och inte bara av strategin: det är
    ``rasterization`` som hänger beloppsgradienten på ``means2d``, och utan den
    faller ``DefaultStrategy`` på ``'Tensor' object has no attribute 'absgrad'``.

    2DGS (``rasterization_2dgs`` med normal- och distorsionsvillkor) är prövat
    och förkastat: överskottet mot ytan föll 2,5 → 1,9 mm men kantskärpan gick
    0,62 → 0,54× och kornet 5,67 → 5,91×, alltså sämre på båda bildmåtten.
    """
    import torch
    from gsplat import rasterization

    width, height = view["size"]
    # Graden läses ur formen i stället för att skickas med: en färg per gaussare
    # är (n, 3), sfäriska harmoniker (n, k, 3). Då kan varje anropare — träning,
    # syntetiska keyframes, verktygen — mata in en modell utan att veta vilket.
    # Träningen håller de högre graderna för sig för takten skull och fogar ihop
    # dem här; en färdig modell bär dem redan hopfogade.
    colors = parameters["colors"]
    if "sh" in parameters:
        colors = torch.cat([colors, parameters["sh"]], dim=1)
    render, _, info = rasterization(
        means=parameters["means"],
        quats=torch.nn.functional.normalize(parameters["quats"], dim=-1),
        scales=torch.exp(parameters["scales"]),
        opacities=torch.sigmoid(parameters["opacities"]),
        colors=colors,
        sh_degree=(round(colors.shape[1] ** 0.5) - 1 if colors.dim() == 3
                   else None),
        viewmats=view["viewmat"] if viewmat is None else viewmat,
        Ks=view["K"],
        width=width,
        height=height,
        render_mode="RGB",
        absgrad=absgrad,
        # Pinnat, inte ärvt: ``DefaultStrategy`` läser ``info["radii"]`` som
        # (kameror, gaussare, 2) och faller på ``tuple index out of range`` om
        # gsplat råkar ha packat ihop dem till (nnz, 2) i stället.
        packed=False,
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
