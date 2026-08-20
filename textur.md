# Vad som faktiskt är uppmätt om färgen

Anteckningar över mätningar på bakningen och splatten, så att en teori som redan
är avfärdad inte behöver avfärdas en gång till. Varje rad här kommer ur en
körning mot ett riktigt skannat rum, inte ur resonemang.

Två regler som mätningarna själva har lärt ut:

- **Döm aldrig en splat ur ett enda tal.** L1 mot fotot belönar suddighet och
  belönar dimma. Rendera bilden, och lägg en TRÄNAD vy bredvid en undanhållen.
- **När en ytregel inte biter, misstänk ytan.** Mät mot den råa meshen.

## Skärpan är gaussare per kvadratmeter

Det här är svaret på varför splatten såg ut som en pastellmålning, och det tog
lång tid att komma fram till för att varje delmätning pekade åt fel håll.

Det avgörande försöket: träna på ett antal GRANNFOTON av samma hörn, och döm
alltid mot samma foto (nummer 40 av 120, i skärpa helt medelmåttigt — rank 63).

| foton | L1 | skärpa mot fotot |
|---|---|---|
| 1 | 0,0642 | 80 % |
| 2 | 0,0258 | 85 % |
| 4 | 0,0225 | 82 % |
| 8 | 0,0347 | 82 % |
| 16 | 0,0376 | 85 % |

Sexton foton av ett hörn ger en rendering som i praktiken inte går att skilja
från fotografiet. Samma modell, samma antal steg, samma budget och ungefär lika
många gaussare (287 883) som körningen på hela rummet — som ger 40 %. Enda
skillnaden är att ytan är ungefär sju gånger större.

Att två foton är BÄTTRE än ett avfärdar samtidigt teorin att grannposer är
oense med varandra: vore poserna fel skulle det andra fotot ha skadat.

Budgeten svarar därefter, mätt på hela rummet (15 000 steg, ytspärren av):

| tak | gaussare kvar | undanhållen L1 | skärpa |
|---|---|---|---|
| 400 k | 220 063 | 0,1211 | 40 % |
| 1 M | 455 021 | 0,1241 | 49 % |
| 2 M | 771 156 | 0,1288 | 58 % |

Kurvan har ännu inte planat ut. L1 blir marginellt sämre medan bilden blir
uppenbart skarpare — se regeln om att inte döma ur ett enda tal.

Det var PLY-formatets 68 byte per gaussare som satte det gamla taket på 400 000.
SPZ tar 20, alltså bär samma nedladdning tre gånger fler; det är därför
`write_spz` finns och varför `PHONE_SPLAT_BUDGET` kunde höjas till 2 M.

## Ytspärren stannar, trots att L1 säger emot

`MAXIMUM_DRIFT` av och på, 15 000 steg, samma rum. Dimman mäts som andel av den
opacitetsviktade massan mer än 5 cm från LiDAR-ytan, med samma `cKDTree` över
`connected_surface` som träningen använder — annars går talet inte att jämföra
med konstanten.

| | gaussare | undanhållen L1 | skärpa | dimma |
|---|---|---|---|---|
| spärr (0,02) | 196 507 | 0,1361 | 38 % | 0,0 % |
| fri | 219 986 | 0,1225 | 40 % | 44,6 % |

Fri träning vinner på båda talen och lägger ändå nästan halva massan i luften
mellan kameran och väggen. L1 belönar alltså dimma: en slöja framför väggen kan
återge just de foton den tränades på. Spärren stannar.

## Fotonas egen skärpa spänner elva gånger

Över en skanning på 120 bilder: minst 0,0048, median 0,0143, mest 0,0549.
`bake.py` har alltid vägt fotona med `SHARPNESS_POWER`; `splat.train` väger dem
lika. Att välja ut foton efter skärpa hjälper skärpan men förstör geometrin:

| urval | skärpa | undanhållen L1 |
|---|---|---|
| 30 skarpaste | 70 % | 0,2669 |
| 30 slumpade | 65 % | 0,1701 |
| 30 suddigaste | 36 % | 0,2797 |
| 60 skarpaste | 55 % | 0,1729 |

Att vikta förlusten per foto efter skärpa är alltså rimligt och oprövat. Att
GALLRA bort foton är det inte — färre foton betyder färre kvadratmeter täckta,
och det är precis vad avsnittet ovan säger är den bindande resursen.

## Renderaren är frikänd — mätt mot en känd god fil

Inrias förtränade `train` (559 263 gaussare, SH-grad 3) lagd i appens mapp och
visad med `BenchmarkSplatView` renderas FOTOREALISTISKT på telefonen: loknumret
713, texten WESTERN PACIFIC, nitarna och gruset går att läsa. Samma Metal-väg,
samma shader, samma projektion som rummet. Suddigheten ligger alltså i vad vi
matar in, inte i hur det ritas — sluta leta i `SplatRoomView` och shadern.

Två saker måste vara rätt för att provet ska säga något:

- **Kameran måste stå i en av datasetets egna poser.** Ur en fritt vald bana ser
  scenen ut som färgat dis, precis som `reach` beskriver för vårt rum. Därför
  hämtar `server/tools/fetch_benchmark.py` även `cameras.json`.
- **Målets färgrum följer filen.** Vår egen splat matas in förkompenserad och
  vill ha ett rått mål (`matchingTraining`); en främmande fil matas in orörd och
  vill ha `.bgra8Unorm_srgb`. Fel val ger en mörk och övermättad bild.

## Referensrummen är bättre än vårt — men inte heller perfekta

`train` var ett föremål man går RUNT. Provet gjordes om med Inrias inomhusrum,
som ställer samma fråga som vi: `drjohnson`, `playroom`, `kitchen`. De renderas
bättre än vårt rum, men inte fotorealistiskt, och de tappar skärpa så fort
kameran lämnar en av sina egna poser.

Två svar i ett:

- **Taket är lägre än "perfekt".** Referensimplementationen på ett städat
  dataset med hundratals systemkameror når inte dit heller. Ett mål som lyder
  "skarpt som ett foto ur vilken vinkel som helst" är alltså ingen kravlista
  utan en önskan. Rätt mål är att en nisch går att se och bedöma.
- **Sfäriska harmoniker är slutgiltigt avfärdade.** `drjohnson` är tränad med
  SH-grad 3 och vårt rum med grad 0 — men MetalSplatter läser bara `sh0`, så
  BÅDA ritades utan vinkelberoende färg. Skillnaden kan därför omöjligt vara SH.
  Det som skiljer är geometri, postäthet och fotokvalitet.

## Fotobudgeten band, inte handen som skannade

När renderaren väl var frikänd stod bara indatan kvar, och det första svaret var
att be kunden skanna närmare och långsammare. Det var fel svar: kunden hade
redan gjort det, och vi kastade bort skanningen.

`KeyframeRecorder` pollar fem bildrutor i sekunden. Tre minuters skanning
erbjuder alltså omkring niohundra tillfällen — vi behöll 120, och krävde 20 cm
eller 12° mellan dem. Taket satt i vår kod.

Det stämmer med det som redan var mätt: skärpan är gaussare per kvadratmeter,
och antalet gaussare en yta får är antalet foton som ser den. Sexton grannfoton
av ETT hörn ger 85 % av fotots skärpa; hundraåtta foton spridda över hela rummet
ger 40 % med lika många gaussare. Inrias `train`, som renderas fotorealistiskt,
har 301 foton av ett enda lok.

Ändrat: budgeten 120 → 300, tröskeln 20 cm/12° → 12 cm/8°. Kostnaden är
uppladdningen, knappt en halv megabyte per keyframe med djupet.

Träningen höll alla foton som float32 på kortet, 21 MB styck — vid 300 blir det
6,4 GB bara i foton. De ligger som uint8 nu och räknas om i det steg som drar
dem: 1,6 GB, och omräkningen syns inte mot rasteriseringen.

## Budgeten mättas vid 680k — MCMC och ytspärren motarbetar varandra

Skanning med 297 foton och full täckning (`coverage_check.py`: median 100 % per
foto, både golv och tak i meshen). Tränade 2 000 000 gaussare, exporten behöll
682 495. Uppdelat på villkoren i `_trimmed`:

| villkor | antal |
|---|---|
| utanför rummet | **0** |
| under `MINIMUM_OPACITY` | 1 317 505 |

Lådtestet binder alltså aldrig — `MAXIMUM_DRIFT` garanterar redan det. Och de
svaga är genuint svaga: median 0,0098, 90:e percentilen 0,0351. Att sänka golvet
tar tillbaka dimman, inte skärpan.

Alltså är **budgeten mättad**: taket på 2 M ger 682k användbara, vilket ligger
på kurvans 58 %. Ett högre tak ger inte fler.

Varför syns i `drog tillbaka`:

| steg | gaussare | drogs tillbaka |
|---|---|---|
| 5 500 | 2 000 000 | 1 550 912 (78 %) |
| 29 500 | 2 000 000 | 549 541 (27 %) |

MCMC:s hela mekanism är att flytta slocknade gaussare dit felet är störst.
Ytspärren flyttar dem sedan igen, varje steg. Den omplacerade hamnar inte där
MCMC ville, hjälper inte, slocknar på nytt och flyttas igen — en snurr som
förbrukar två tredjedelar av budgeten utan att ge en enda synlig gaussare. Samma
kvot mättes vid 400k-taket (114k av 400k, 28,5 %), så det har aldrig varit
åtgärdat, bara uppskalat.

Nästa steg är därför ingen konstant, utan att sluta låta reglerna slåss: låt
omplaceringen välja destination PÅ den mätta ytan, så har projektionen ingenting
att ångra. Oprövat.

Samma körning, för protokollet: poserna flyttade sig 11,0 mm i median (max
21,5), exponeringsrättelsen spände 0,69–1,15 gånger. Båda gör alltså något.

## Radietaket är inte längre bindande — FEL, se nedan

**Den här slutsatsen är kullkastad** av "Skärpan satt i radietaket, inte i
antalet". Den står kvar för att felet i resonemanget är värt att känna igen:
allt nedan är riktigt mätt, men mätt på medianaxeln, och medianen renderar inte
bilden. Frågar man renderaren i stället täcks varje pixel av 339 gaussare.

Om av på hela rummet vid 2 M-budgeten, 30 000 steg, undanhållna foton:

| tak | L1 | skärpa | hål | gaussare | medianaxel |
|---|---|---|---|---|---|
| 50 mm | 0,1148 | 61 % | 10,2 % | 877 277 | 20,8 mm |
| 25 mm | 0,1235 | 62 % | 12,7 % | 884 089 | 23,3 mm |

Skärpan står stilla, L1 blir sämre och hålen växer. Det avgörande talet är
medianaxeln: vid gamla budgeten låg den på 44 mm med 95:e percentilen exakt på
taket, alltså band taket nästan allt. Nu ligger den långt under. Med fyra gånger
fler gaussare väljer träningen redan små — att tvinga dem mindre ger bara hål.

## Avfärdat med mätning, försök inte igen

- **Straffen i förlusten** (opacitet, skala) — ingen mätbar skillnad på skärpan.
- **Sfäriska harmoniker över grad 0** — MetalSplatter har ingen SH-väg alls, så
  koefficienterna hade ändå aldrig nått fram till skärmen.
- **Platta skivor vid SEEDNINGEN** — en pixels vinst, inom bruset. Formen måste
  hållas under träningen för att betyda något, se `MAXIMUM_THICKNESS`; startvärdet
  optimeras bort på några hundra steg.
- **Radietak under 5 cm** — se avsnittet ovan. Mindre penslar utan fler penslar
  är glesare täckning, inte mer detalj.
- **Färre steg** — sämre på allt.
- **Fragmentering och mipmapping i atlasen** — nästan oskyldiga. Läs atlasen i
  FULL upplösning innan du tror på en teori om smetet; vid 1:1 syns boktitlar.
- **Skärpevikt och atlasupplösning** (`SHARPNESS_POWER`, `BLEND_THRESHOLD`,
  `targetWidth = 1536`, `DEFAULT_ATLAS_SIZE = 4096` ≈ 1,8 mm per texel) är
  avklarade kapitel. Höj båda upplösningarna eller ingen.

## Två fel som såg ut som oskärpa men inte var det

1. **Dimma.** Fritt tränad lägger sig splatten mellan kameran och väggen: 74 %
   av gaussarna mer än 2 cm från ytan, 91 % av massan, största radie 1,46 m.
   Gallring i EXPORTEN går inte — träningen lutar sig mot dimman. `MAXIMUM_RADIUS`
   och `MAXIMUM_DRIFT` klipper i `train` varje steg i stället.
2. **ARKits lösa flagor.** Den råa meshen faller i 435 delar, varav 419 är flagor
   (1,76 m² av 67) som svävar 35 cm ut från väggen. `splat.train` läste rått och
   sådde på dem, och `MAXIMUM_DRIFT` såg dem inte — de RÄKNAS som yta. Städningen
   bor nu i `bundle.connected_surface` och båda vägarna kallar den: 4,7 % → 1,3 %
   av massan i luften.

Ett tredje, som såg ut som oskärpa och var det: **exportens volymgallring** vägde
opacitet × VOLYM och behöll de rundaste. En platt skiva som täcker en vägg skarpt
har liten volym och slängdes. Nu äger träningen taket. Mät `mid/min` för
platthet, aldrig `max/min`.

## Förgrundssmetet är ett hål i skanningen, inte i splatten

Efter höjd budget är rummet skarpt utom i förgrundens golv, som smetar ut i
radiella strimmor. Det är frestande att skylla på gaussarnas storlek. Mätningen
säger något annat: av 179 440 hörn i den RÅA meshen ligger bara **345** inom
15 cm från golvnivån, och `connected_surface` behåller 304 av dem. Projicerat in
i vyn är den nedre högra fjärdedelen — exakt det utsmetade området — helt tom på
mätt yta. Städningen är alltså oskyldig; ARKit mätte aldrig golvet, för
telefonen hölls mot väggar och bänkar.

Med hål i ytan blir ytspärren dessutom aktivt skadlig just där: gaussarna som
skulle täckt golvet har ingen yta att hänga på och dras i stället mot närmaste
ytpunkt, som är väggen. Därav strimmorna. Åtgärden hör hemma i skanningen — svep
över golvet — inte i träningen.

Kontrollen finns som mönster: projicera `connected_surface` in i en keyframes
pose och räkna punkter per ruta. Ett smetigt område med noll ytpunkter är ett
hål i indata och inget annat.

## Skärpan satt i radietaket, inte i antalet

Fyra saker prövades i tur och ordning mot samma skanning (297 foton), var och en
med bara EN variabel ändrad. De tre första gav ingenting, och det är de som är
värda att komma ihåg:

| ändring | gaussare | skärpa | dimma |
|---|---:|---:|---:|
| utgångsläget | 682 495 | 54,6 % | 15,6 % |
| ytspärren klämmer varje steg | 530 264 | 52,5 % | 6,5 % |
| straffen på opacitet och skala borta | 1 273 245 | 51,2 % | 5,0 % |
| kamerorna låsta vid ARKits poser | 439 991 | 40,2 % | 7,0 % |

Att 2,4 gånger fler gaussare gav SÄMRE skärpa är hela poängen: antalet var inte
det som band. Låsta poser föll till 40 % trots att de mäts i sina egna poser,
vilket friar mätningen från att vara artefakten.

Först när talen tog slut renderades bilden och tittades på. Då syns det: ett
pärlemorskimrande dis över väggarna, i **gsplats egen rendering på servern** —
alltså inte telefonens shader, som friats separat. Frågan gick sedan till
renderaren i stället för till modellen, via `info` från `rasterization`:

> Vid 5 cm radietak projicerar mediangaussaren till **18 pixlars radie** på en
> bild som är 1536 bred, och varje pixel täcks av **339 gaussare**. De som täcker
> mest ligger klistrade mot taket: största halvaxel 4,8 cm av 5,0 tillåtna.

Rummet var alltså inte en yta utan trehundra halvgenomskinliga lager, och
blandningen av dem ÄR diset. Taket hade tidigare avfärdats med att medianaxeln
låg på 20,8 mm — men medianen renderar inte bilden, det gör de största.

| radietak | budget | gaussare | skärpa |
|---|---|---:|---:|
| 5 cm | 2 M | 530 264 | 52,5 % |
| 2 cm | 2 M | 779 189 | 55,0 % |
| 8 mm | 2 M | 1 729 853 | 70,3 % |
| 8 mm | 3 M | 2 428 287 | 71,9 % |
| 6 mm | 3 M | 2 738 817 | 82,4 % |
| 4 mm | 3 M | 2 919 128 | 107,3 % |

En halv miljon extra gaussare vid oförändrad radie gav 1,6 procentenheter; en
fyra gånger mindre radie gav arton. Det tidigare budgetsvepet (220k/455k/771k →
40/49/58 %) mätte i själva verket radien genom budgeten — fler gaussare på samma
yta tvingar fram mindre.

Valet blev först 4 mm och budget 3 M. Skärpetalet passerar hundra procent där,
vilket inte betyder skarpare än verkligheten utan att renderingen fått ett korn
fotot saknar — två fel som delvis tar ut varandra. **Bilderna, inte talen,
skilde 4 från 6 mm:** vid sex millimeter ligger diset kvar nedtill, vid fyra är
väggen ren. Kornet bedömdes vara det mindre av felen.

Det var fel bedömning, och det syntes först på telefonen.

## Kornet var klot — gaussarna måste hållas platta

4 mm-splatten på telefonen såg ut som ull: hela rummet fibrigt, som stucco.
Serverbilden hade samma korn, men i 600 pixlars bredd såg det ut som en
struktur man kunde leva med. **Bedöm aldrig kornighet i en nedskalad bild** —
zooma in på en bit slät vägg i full upplösning.

Två förklaringar prövades och föll:

- **Hål mellan gaussarna.** Nej: täckningen var 51 bildytor och bara 0,85 % av
  bilden helt tom. Det finns gott om överlapp.
- **Närplanet.** Nej: gsplats förval är 1 cm, men kameran kom aldrig närmare än
  **26 cm** från en yta under hela skanningen, så inget projiceras uppblåst.

Svaret satt i FORMEN. Halvaxlarna vid 4 mm:

> mellersta axeln **1,1** gånger den minsta, största **1,00** gånger den
> mellersta — alltså klot, inte skivor, alla tre axlar tryckta mot taket.

`MAXIMUM_RADIUS` klämmer bara den största axeln, så när taket sänks samlas allt
mot det och rundas av. En vägg byggd av 4 mm klot är bucklig av sig själv, och
att sänka taket ytterligare gör bara kloten mindre. `SEED_THICKNESS` sår dem
redan som skivor, men startvärdet optimeras bort på några hundra steg — **formen
måste hållas under träningen, inte bara sättas vid starten.**

Åtgärden är `MAXIMUM_THICKNESS`, ett eget tak på den TUNNASTE axeln, klämt varje
steg. Vilken av de tre som är tunnast bestäms av kvaternionen och byts under
träningen, så den måste letas upp med `argmin` varje gång.

| radietak | tjocklek | gaussare | skärpa |
|---|---|---:|---:|
| 2 cm | 2 mm | 989 117 | 58,7 % |
| 1 cm | 1 mm | 2 145 976 | 68,4 % |
| 8 mm | 1 mm | 2 517 633 | 74,2 % |
| 6 mm | 1 mm | 2 786 113 | 86,1 % |
| 4 mm | 0,8 mm | 2 935 585 | 115,1 % |

Platthet 1,1 → **7,4**, och skärpan 82 → 86 % vid samma radie. Valet blev
**6 mm × 1 mm, budget 3 M**: kornet nästan borta, diset kvar bara som en aning.

Straffen mättes om samtidigt och är nu helt verkningslösa (86,1 mot 86,3 utan
dem) — ytspärren har tagit över deras jobb.

Ytspärren skrevs samtidigt om till att klämma varje steg mot en cachad ytpunkt
i stället för att projicera var 250:e. Den gav ingen skärpa, men den gör
gränsen sann: dimman är nu **0,0 %** i alla modeller, mot 15,6 % förut. Skälet
den behövdes är att MCMC skakar lägena med ett brus som över 250 steg
slumpvandrar √250 gånger längre än ett steg — 78 % av budgeten fick ryckas
tillbaka flera centimeter vid steg 5 500, mot 3 % per steg nu.

## Rutiner

- **Sätt siffror på splatten med `server/tools/splat_check.py`** innan du tror på
  en ändring. Träningsloggens förlust duger inte: den gäller ETT slumpat foto och
  svänger mer mellan två utskrifter än två modeller skiljer sig åt.
- **När talen tar slut, rendera bilden och titta på den.** Fyra mätningar i rad
  pekade åt fel håll här; jämförelsebilden gav svaret på en gång.
- **Titta i FULL upplösning på en bit slät vägg.** Kornighet försvinner i en
  nedskalad översiktsbild och kom tillbaka först på telefonen.
- **Skärpetalet mäter två fel med olika tecken** — dis drar det nedåt, korn
  uppåt. Ett tal över 100 % är sämre än ett strax under, inte bättre.
- **Mät formen, inte bara storleken:** `mid/min` på halvaxlarna. Ett tak på den
  största axeln gör gaussarna till klot om ingenting håller den minsta.
- **Fråga renderaren, inte modellen.** `info` från `rasterization` bär `radii`
  och `depths` per gaussare — projicerad storlek på skärmen är det som avgör vad
  man ser, och den går inte att räkna ut ur halvaxlarna i huvudet.
- **Mät dimma med marginal** (`> MAXIMUM_DRIFT * 1.5`). Träningen klämmer de
  drivna till precis gränsen, så utan marginal räknas varje klämd gaussare som
  dimma och måttet visar 6,8 % för en modell som per konstruktion har noll.
- **Kolla vilken färgkälla bakningen faktiskt körde** innan du tror på en
  förbättring: `grep "tränade" /tmp/bake.log`. Saknas raden var det `blend`.
- **Döm aldrig bakningen ur atlasbilden — rendera meshen** med
  `server/tools/render_check.py`, ur en keyframes pose med fotot bredvid.
- **Starta om uvicorn efter varje synk.** Den cachar moduler, och en bakning med
  gammal kod gör all mätning till lögn.
- "Randomiserade färger" eller konfetti på skärmen betyder ett OBAKAT rum, inte
  en trasig splat.
