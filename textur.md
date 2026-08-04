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

## Radietaket är inte längre bindande

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
- **Platta skivor vid seedningen** — en pixels vinst, inom bruset.
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

## Rutiner

- **Kolla vilken färgkälla bakningen faktiskt körde** innan du tror på en
  förbättring: `grep "tränade" /tmp/bake.log`. Saknas raden var det `blend`.
- **Döm aldrig bakningen ur atlasbilden — rendera meshen** med
  `server/tools/render_check.py`, ur en keyframes pose med fotot bredvid.
- **Starta om uvicorn efter varje synk.** Den cachar moduler, och en bakning med
  gammal kod gör all mätning till lögn.
- "Randomiserade färger" eller konfetti på skärmen betyder ett OBAKAT rum, inte
  en trasig splat.
