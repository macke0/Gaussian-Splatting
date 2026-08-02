# SpatialFit — Steg 1: MVP av kollisionsmotorn

Proof-of-concept för den geometriska passformsmotorn: en mockad köksnisch på
600 mm, en produktväljare i botten, och zonlogik (🟢/🟡/🔴) med pulserande
krockvolymer och varningsmodal.

Scenen körs med **virtuell kamera**, inte AR-passthrough. Det gör att demot
fungerar i simulatorn och på iPhones utan LiDAR — och att kollisionsmotorn kan
demonstreras för en kedja utan att någon behöver skanna ett rum först.

## Kom igång

`SpatialFit.xcodeproj` ligger i repot. Öppna det och kör på simulator eller
enhet — deployment target är **iOS 18.0** (`RealityView`, `MagnifyGesture`,
`@Observable`, `symbolEffect`).

Båda targets använder Xcodes synkroniserade filgrupper: filer som läggs till i
`SpatialFit/` respektive `SpatialFitTests/` på disk kommer automatiskt med i
bygget. Ingen `pbxproj`-redigering behövs för nya källfiler.

Från terminalen:

```bash
xcodebuild -scheme SpatialFit -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild test -scheme SpatialFit -destination 'platform=iOS Simulator,name=iPhone 17'
```

Ingen kamerabehörighet behövs i steg 1. Först när `content.camera` sätts till
`.worldTracking` krävs `NSCameraUsageDescription` i Info.plist.

## Vad du ser

| Produkt | Mått (b×h×d) | Marginal i bredd | Zon |
|---|---|---|---|
| Induktionsspis 60 cm | 580 × 850 × 600 | +20 mm | 🟢 grön ram |
| Kombispis 60 cm | 596 × 890 × 620 | +4 mm | 🟡 gul ram, "kontrollmät" |
| Range Cooker 90 cm | 900 × 880 × 600 | −300 mm | 🔴 krock, 150 mm per sida |

Den gula produkten är inte med i den ursprungliga specen — jag lade till den
för att gula zonen är den enda som är svår att sälja in. 596 mm i en 600 mm
nisch *passar på pappret* och är i praktiken den vanligaste returorsaken.
Utan ett gult case i demot ser zonsystemet ut som en binär ja/nej-kontroll.

Dra för att rotera, nyp för att zooma.

## Flödet i appen

1. **Mina rum** (`RoomLibraryView`) — rummen kunden redan skannat, sparade på
   disk. Tom första gången.
2. **Skanna rum** (`RoomScanView`) — RoomPlans egen vy. När skanningen är klar
   visas en sammanfattning, rummet får ett namn och sparas.
3. **Rummet i 3D** (`RoomViewerView`) — den rekonstruerade LiDAR-mesh:en, inte
   de parametriska boxarna. Kameran kretsar kring rummets mitt: dra för att
   vrida, nyp för att gå in i eller ut ur rummet.
4. **Lägg till produkt** (`ProductPlacementView`) — välj nisch, prova produkter
   mot den. Det är här kollisionsmotorn från steg 1 kopplas in.

Ett sparat rum ligger i en egen mapp under `Application Support/Rooms/<id>/`:
`room.mesh` med den täta LiDAR-ytan, `room.usdz` med RoomPlans export,
`room.json` med `CapturedRoom` så att nischerna kan räknas om när mätlogiken
förbättras — utan att kunden skannar om — samt `keyframes.json` och fotona som
målar rummet. Nischerna räknas därför om vid visning i stället för att cachas.

### Geometrin kommer från ARKit, inte från RoomPlan

RoomPlan är en *tolkning*: väggar som plan, möbler som orienterade lådor med en
kategori. Det är exakt rätt underlag för att mäta en nisch, men en diskbänk är
inte en låda. Exporteras rummet med `USDExportOptions.mesh` är det fortfarande
lådor — och projicerar man foton på lådor smetas bilderna ut, eftersom ytan de
målas på inte är den yta de fotograferade.

Den täta ytan finns redan. RoomPlan bygger sin tolkning ovanpå ARKits
scenrekonstruktion, och ARKit lägger den som `ARMeshAnchor` i sessionen.
`SceneMeshRecorder` läser dem när skanningen avslutas — anchors slås ihop
löpande, så en enda avläsning på slutet ger hela rummet. Den måste ske innan
sessionen stoppas; efteråt är de borta.

`SceneMesh` är formatet på disk och håller sig till lagerregeln: bara Foundation
och simd. Det är avsiktligt rått binärt — ett par hundra tusen hörn som JSON blir
tiotals megabyte text. Hörnen skrivs packade till 12 byte, inte de 16 en
`SIMD3<Float>` upptar i minnet. Vid inläsning avvisas filen om ett index pekar
utanför hörnlistan: RealityKit kraschar på det i stället för att kasta.

Rum skannade innan ytan började sparas — och enheter utan scenrekonstruktion —
faller tillbaka på USDZ-exporten.

### Rummet målas med dina egna foton

RoomPlan levererar geometri, inte färg. Färgen kommer i stället från kameran.

Under skanningen exponerar `RoomCaptureSession` sin `arSession`. `KeyframeRecorder`
pollar den och sparar upp till 40 **keyframes** — foto, kamerans placering,
brännvidd och LiDAR-djupkartan. En bildruta blir en keyframe först efter 30 cm
eller 20° förflyttning, annars fylls disken med samma vägg fyrtio gånger.

`RoomTexturizer` målar sedan mesh:en. **Ingen texturatlas byggs.** I stället
grupperas trianglarna efter vilken bild som såg dem bäst, och varje grupp blir
en egen del med den bilden som textur. Det ger full fotoupplösning utan att
packa om pixlar, och kostar en ritning per keyframe.

Först delas geometrin upp så att ingen triangelkant är längre än 30 cm.
LiDAR-ytan är redan finmaskig, men faller rummet tillbaka på USDZ-exporten är en
vägg ett par stora trianglar som inte ryms i ett foto taget en och en halv meter
bort — den skulle med krav 1 nedan aldrig bli målad alls. Uppdelningen sker på
kantmitterna, så ytan förblir tät, och har en budget — en enda vägg får inte
kunna bli hundratusen bitar.

`ViewSelection` avgör vilken bild som vinner. Tre krav, alla nödvändiga:

1. **Alla tre hörnen syns i bilden.** Räcker bilden inte till hela triangeln
   sträcks texturen över kanten och rummet blir randigt.
2. **Ytan är vänd mot kameran** (`cos ≥ 0.35`) och närmare än 4,5 m. En vägg
   fotograferad snett bakifrån eller från andra sidan rummet ger utsmetade
   pixlar.
3. **Ytan låg faktiskt främst.** LiDAR-djupet i keyframen jämförs med
   triangelns avstånd, med 12 cm marginal för brus. Utan det testet målas
   väggen bakom en spis rakt ut över spisen.

Bland kandidaterna vinner `facing / distance` — rakt på och nära.

Det räcker inte. Poängen växlar snabbt över en yta, så det bästa fotot skiftar
från triangel till triangel. Var för sig är valen riktiga, men resultatet blir
ett lapptäcke där varje lapp har sin egen exponering och sin egen lilla
feljustering. `ViewSelection.assign` jämnar därför ut valet: en triangel byter
till den bild fler än hälften av dess grannar redan använder, så länge den
bilden inte är påtagligt sämre. Grannskapet byggs ur hörnens läge avrundat till
millimeter, eftersom trianglarna kommer utan delade index. Uppdateringen sker på
plats — räknade man fram alla nya val ur de gamla skulle två grannar kunna byta
med varandra i all evighet utan att någonsin mötas.

Ytor som ingen bild dög till målas inte — men de renderas ändå, i grått. Utan
dem är resultatet inte ett rum med hål i, utan lösryckta fotolappar i luften.

Materialet är `UnlitMaterial` med flit: ljuset ligger redan i fotot. Med PBR och
scenens lampor blir rummet dubbelbelyst. Den grå mesh:en finns kvar som
växelläge i verktygsfältet, eftersom den visar var geometrin har hål — det
döljer fotona.

## Arkitektur

```
SpatialFit/
├── Model/
│   ├── Units.swift          mm ⇄ m på exakt ett ställe. Axis, Dimensions3D.
│   ├── Geometry.swift       BoxAABB, Obstacle, Intersection. Ren simd.
│   ├── Product.swift        PIM-bounding box + demokatalog.
│   ├── RoomElement.swift    Skannat rum som orienterade lådor — utan RoomPlan.
│   ├── SavedRoom.swift      Metadata om ett sparat rum. Bara Foundation.
│   ├── SceneMesh.swift      Den täta LiDAR-ytan + dess binärformat på disk.
│   ├── Keyframe.swift       Foto med känd pose. Projektion + djupuppslag.
│   └── Niche.swift          Niche, MeasurementSource, NicheSource-protokollet,
│                            MockKitchenNiche.
├── Engine/
│   ├── FitResult.swift      FitPolicy, AxisClearance, FitZone, texterna.
│   └── CollisionEngine.swift  evaluate() / placement() / intersections().
├── Measurement/             Rum och punktmoln → mått. Ren simd, testbar utan enhet.
│   ├── DepthSample.swift    Djuppunkt i världskoordinater + confidence.
│   ├── PlaneFit.swift       Robust planpassning med medelfel.
│   ├── NicheMeasurer.swift  Punktmoln + grovt utgångsläge → NicheMeasurement.
│   └── NicheFinder.swift    [RoomElement] → ScannedNiche i nischens egen bas.
├── ARKit/
│   ├── DepthPointCloud.swift  ARFrame → [DepthSample].
│   ├── SceneMeshRecorder.swift  ARMeshAnchor → SceneMesh i världskoordinater.
│   └── KeyframeRecorder.swift  Foto + pose + djup, sparat under skanningen.
├── Texturing/
│   └── ViewSelection.swift  Vilken bild målar vilken triangel. Ren simd.
├── RoomPlan/
│   ├── CapturedRoomReader.swift  CapturedRoom → [RoomElement] +
│   │                        RoomPlanNicheSource.
│   ├── RoomScanModel.swift  Skanningens tillstånd + RoomCaptureViewDelegate.
│   └── RoomStore.swift      Sparade rum på disk: LiDAR-yta, USDZ, CapturedRoom.
├── RealityKit/
│   ├── PulseSystem.swift    ECS-system för pulserande varningsmaterial.
│   ├── EntityFactory.swift  lådor, trådramar, måttetiketter.
│   ├── SceneMeshEntity.swift  SceneMesh → ritbar entitet, normaler och allt.
│   ├── RoomSceneController.swift  Orbitrigg för att gå runt i ett skannat rum.
│   ├── RoomTexturizer.swift  Mesh + keyframes → fotograferat rum.
│   └── FitSceneController.swift  FitResult → entiteter. Enda filen som känner
│                            till både affärslogik och RealityKit.
├── ViewModel/FitDemoModel.swift
├── Views/                   RoomLibraryView, RoomScanView, RoomViewerView,
│                            ProductPlacementView, FitDemoView, FitBadgeView,
│                            CollisionAlertView, ProductPickerBar.
└── App/SpatialFitApp.swift
```

Beroendeflödet går **bara nedåt**: `Model` känner inte till `Engine`, `Engine`
känner inte till RealityKit, RealityKit-lagret känner inte till SwiftUI.
`CollisionEngine` importerar bara `Foundation` och `simd` — den kan köras
headless, t.ex. för att batch-validera en hel PIM-export mot ett skannat kök.

### Zonlogiken

`FitPolicy.greenClearanceMM = 15` — total marginal, summan av båda sidor.
Varje axel bedöms för sig, sämsta axeln avgör helheten:

```
clearance = nisch − (produkt + installationsmarginal)
clearance <  0   → 🔴  overhangPerSide = |clearance| / 2
clearance < 15   → 🟡
annars           → 🟢
```

Två saker är förberedda men avstängda som default:

- `Product.installationClearance` — extra krav utöver PIM-boxen
  (ventilationsspalt bakom kyl, svängradie för lucka). Läggs på per axel.
- `FitPolicy.addsScanTolerance` — lägger skanningens mätosäkerhet ovanpå
  gröngränsen. Med RoomPlan (±15 mm) betyder det att grön zon kräver 30 mm.
  Det är förmodligen rätt beteende i skarp drift, men det gör demot förvirrande,
  så det är `false` här.

### Mätprecisionen

Ett vanligt löfte i den här produktkategorin är "millimeterprecision med LiDAR".
Rakt av är det inte sant: en enskild djuppunkt från iPhonens LiDAR ligger i
storleksordningen ±10 mm fel på en meters håll. Ingen efterbehandling gör en
punkt tio gånger bättre.

Det som däremot går är att sluta mäta punkter och börja mäta **ytor**. Medelfelet
för ett plan passat genom *n* punkter är σ/√n — 2 000 punkter mot en skåpsida ger
planets läge på ~0,2 mm. Det är den mekanismen `Measurement/` bygger på:

```
[DepthSample]  →  PlaneFitter.fit  →  NicheMeasurer.measure  →  Niche
   ±10 mm/punkt     plan + medelfel      mått + osäkerhet        toleranceMM
```

Tre saker gör skillnaden mellan att det fungerar och att det ser ut att fungera:

- **Median före minstakvadrat.** En skåpsidas sökskiva får med sig en remsa av
  golvet där de möts. Den kontamineringen ligger alltid på samma sida om ytan,
  så den flyttar måttet i stället för att bullra. Minstakvadrat viktar alla
  punkter lika; medianen gör det inte.
- **Hörnen utesluts.** `NicheMeasurer` mäter bara mitt på varje yta. Utan det
  blir felet ~5 mm, vilket vi råkade mäta upp när testerna först föll.
- **Ett golv på osäkerheten.** σ/√n går mot noll, men ARKits världsspårning
  driver och skåpsidan buktar. `NicheMeasurer.systematicFloorMM` sätter
  ±1 mm som lägsta rapporterade osäkerhet — att lova ±0,05 mm vore precis den
  sortens löfte appen finns för att slippa.

`PlaneFit` skiljer på två tal som lätt blandas ihop: `rmsResidualMM` (hur ojämn
ytan är) och `standardErrorMM` (hur säkert planet ligger). Det första avslöjar
att man passat ett plan mot en gardin; det andra är nischens mätosäkerhet.

Resultatet hamnar i `Niche.measuredToleranceMM` och går före källans schablon.
Med `FitPolicy.addsScanTolerance` slår det direkt igenom i zonerna: en välmätt
nisch behåller sin gröna zon där RoomPlans nominella ±15 mm hade tvingat fram
gult.

### Vridna rum

Riktiga kök står inte längs ARKits världsaxlar. Den uppenbara motåtgärden är
att göra motorn tyngre — OBB och SAT i stället för AABB — men det behövs inte.
Problemet är inte att lådorna är fel sort, det är att de uttrycks i fel
koordinatsystem.

`NicheFinder` bygger därför en ortonormal bas ur väggen (längs, upp, ut i
rummet) och uttrycker nisch och hinder i den. Origo läggs i golvhöjd, mitt i
nischens bredd och djup — exakt mockens konvention, så `CollisionEngine` och
`FitSceneController` fungerar oförändrade. I nischens eget system står nischen
rakt per definition, och AABB-matematiken är giltig igen.

`ScannedNiche.worldFromNiche` bär vridningen tillbaka ut till scenen; den sätts
på `AnchorEntity`-transformen när passthrough kopplas in.

Testerna kör hela kedjan mot ett kök som står **31° snett och 2,5 m från
origo**, och kräver millimeterfacit på alla tre axlar. Ett kök som råkar ligga
längs X bevisar ingenting — det är precis det fall där även den gamla koden
fungerade.

OBB + SAT behövs först om nischens egna sidor inte är vinkelräta mot varandra
(förekommer i äldre badrum).

### Krockvolymerna

De röda pulserande lådorna är inte dekoration — de är den faktiska
AABB-skärningen mellan produktens placering och varje hinder, uträknad i
`CollisionEngine.intersections`. Därför hamnar de automatiskt rätt när
nischdata byts ut, och därför visar modalen "Skåpstomme — 150 mm intrång"
per hinder i stället för en generisk text.

Placeringen (`CollisionEngine.placement`) speglar hur en spis faktiskt
installeras: centrerad i sidled, stående på golvet, inskjuten mot bakkant.
Kontakt räknas inte som krock — `epsilon` är 0,5 mm, annars skulle produkten
larma mot golvet den står på.

## Kända begränsningar i prototypen

1. **Skarvarna mellan foton syns.** Utjämningen ger stora sammanhängande
   områden i stället för ett lapptäcke, men där två foton möts finns ett hopp i
   exponering — ingen färgutjämning görs mellan bilderna. Nästa steg vore att
   baka en texturatlas där varje texel blandar flera vyer, i stället för att
   varje triangel väljer en enda. Ytor som ingen bild såg tillräckligt bra
   lämnas omålade och blir grå.
   LiDAR-ytan är dessutom brusig och har hål där LiDAR:n inte nådde — den är
   rätt form, inte en slät form. Att jämna ut och täppa till den (Poisson eller
   liknande) är ett eget steg.
2. **Nischprecisionen är oprövad på riktigt.** `NicheFinder` och
   `CapturedRoomReader` är testade mot syntetisk data. Först mot en tumstock
   visar det sig om RoomPlans skåpsdimensioner räcker för millimetersnack,
   eller om `Measurement/` måste ta över måtten (steg 3).
3. **Ett vridet skåp blir sin omslutande låda.** Hinder projiceras ner på
   nischens bas, så ett skåp som står snett *mot sin egen vägg* blir någon
   millimeter för brett. Mot väggens bas är approximationen tät för allt som
   står längs väggen — och ett skåp som verkligen står snett mot väggen är i
   praktiken felskannat, inte snett.
4. **Krockfärgen sitter på överlappslådan, inte på produktmeshen.** Att färga
   just den del av meshen som skär in kräver en `CustomMaterial` med en Metal
   surface shader som klipper mot krockplanet. `PulseComponent`/`PulseSystem`
   kan behållas oförändrade — bara materialbytet i `PulseSystem.update` skrivs om.
5. **Lådor i stället för USDZ.** Produktkroppen är en grå låda i PIM-boxens
   mått. Riktiga modeller hängs in via `Product.modelAssetName` — men måtten
   måste fortsätta komma från PIM, aldrig från `visualBounds` på USDZ:en.
6. **Scenen ligger i origo.** `ScannedNiche.worldFromNiche` finns och är testad,
   men scenlagret använder den inte förrän kameran byts till `.worldTracking`.

## Nästa steg

**Steg 2 — RoomPlan.** Tolkningen är klar: `RoomPlanNicheSource.niches(in:)` tar
en `CapturedRoom`, plockar väggar, golv, öppningar och objekt, hittar gapen
mellan skåp som står an mot samma vägg och returnerar `Niche` + `[Obstacle]` +
`worldFromNiche`. `source: .roomPlan` sätts, så mätosäkerheten följer med in i
UI:t. **Ingen rad i `Engine/` ändrades** — hela poängen med `NicheSource`.

Skanningsflödet finns och sparar rummet: `RoomScanView` kör RoomPlans egen
`RoomCaptureView`, `RoomStore` skriver mesh + `CapturedRoom` till disk, och
`RoomViewerView` låter kunden gå runt i rummet i 3D. Därifrån går vägen vidare
till `ProductPlacementView`, som väljer nisch och lämnar över till
kollisionsmotorn med nischen ankrad på `worldFromNiche`.

Notera: på iOS heter kameraläget `.spatialTracking`, inte `.worldTracking` —
det senare finns bara på visionOS. `NSCameraUsageDescription` sätts via
`INFOPLIST_KEY_NSCameraUsageDescription` i projektinställningarna.

**Det här går inte att prova i simulatorn.** `RoomCaptureSession.isSupported`
är falskt där, och vyn visar då "Enheten saknar LiDAR" i stället för att
krascha. Kör på en iPhone Pro eller iPad Pro för att verifiera flödet.

**Steg 3 — Precision.** Mätkärnan finns (`Measurement/`, se ovan) och
`DepthPointCloud` läser ut ARKits djupkarta. Det som återstår är limmet:
en `LiDARNicheSource: NicheSource` som ackumulerar punkter över flera bildrutor,
låter användaren peka ut nischen grovt, och kör `NicheMeasurer` på resultatet.
Kvar sedan: "smart edge snap" mot visuella kanter i kamerabilden, för de fall
där två ytor möts utan att LiDAR:n ser skarven.

**Steg 4 — Surface replacement.** Kakel/tapet på `.wall`-ytor:
`MeshResource.generatePlane` från `surface.dimensions`, 2 mm offset längs
väggnormalen mot z-fighting, och UV-repeat = väggmått / plattmått så att
150 mm-plattor behåller sin fysiska skala. Detta hör hemma i en egen
`SurfaceReplacement`-modul bredvid `RealityKit/` och rör inte kollisionsmotorn.

## Tester

`TexturingTests` täcker den matematik som avgör om rummet blir fotoidentiskt
eller utsmetat: att projektionen behåller höger/upp mot ARKits konvention, att
punkter bakom kameran och utanför bildkanten faller bort, att den närmaste
kameran vinner, att en yta sedd från kanten väljs bort, och att djuptestet
kastar bort skymda ytor men tolererar 12 cm LiDAR-brus.

`SpatialFitTests/CollisionEngineTests.swift` täcker zongränserna,
installationsmarginal, mätosäkerhet, krockgeometrin (2 träffar × 150 mm) och
att tangerande ytor inte larmar. Testerna importerar varken RealityKit eller
SwiftUI — hela affärsregeln går att verifiera utan scen.

`SpatialFitTests/NicheMeasurementTests.swift` kör mätkedjan mot ett **syntetiskt
punktmoln** där facit är känt: en 600 × 900 × 650 mm nisch med σ = 10 mm brus per
punkt (i värsta laget för iPhone-LiDAR på en meters håll) och ett utgångsläge som
är 10–20 mm fel. Kravet är under 2 mm fel på varje axel, verifierat över fem
brusutfall så att det inte är turen som testas. Där ligger också testet för att
en 8°-vriden vägg får rätt normal, och för att en yta som saknas i molnet ger
`nil` i stället för ett påhittat mått.

`SpatialFitTests/NicheFinderTests.swift` bygger ett **syntetiskt kök som står
snett**: 31° vridet, 2,5 m från origo, med skåp och ytor uttryckta som RoomPlan
uttrycker dem. Nischen ska mätas till 600 × 900 × 650 mm på under en millimeter
oavsett vridning, transformen ska vara ortonormal och högerorienterad, och
Range Cookern ska ge exakt två krockar på 150 mm var. Där ligger också de fall
där svaret ska vara *ingen nisch*: ett dörrhål mellan skåpen, en köksö som står
ute i rummet, en 120 mm-springa, ett tomt rum.

Kör på ⌘U.
