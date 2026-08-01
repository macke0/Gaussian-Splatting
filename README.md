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

## Arkitektur

```
SpatialFit/
├── Model/
│   ├── Units.swift          mm ⇄ m på exakt ett ställe. Axis, Dimensions3D.
│   ├── Geometry.swift       BoxAABB, Obstacle, Intersection. Ren simd.
│   ├── Product.swift        PIM-bounding box + demokatalog.
│   └── Niche.swift          Niche, MeasurementSource, NicheSource-protokollet,
│                            MockKitchenNiche.
├── Engine/
│   ├── FitResult.swift      FitPolicy, AxisClearance, FitZone, texterna.
│   └── CollisionEngine.swift  evaluate() / placement() / intersections().
├── Measurement/             Punktmoln → mått. Ren simd, testbar utan enhet.
│   ├── DepthSample.swift    Djuppunkt i världskoordinater + confidence.
│   ├── PlaneFit.swift       Robust planpassning med medelfel.
│   └── NicheMeasurer.swift  Punktmoln + grovt utgångsläge → NicheMeasurement.
├── ARKit/
│   └── DepthPointCloud.swift  ARFrame → [DepthSample]. Enda stället som rör
│                            ARKits djupkarta.
├── RealityKit/
│   ├── PulseSystem.swift    ECS-system för pulserande varningsmaterial.
│   ├── EntityFactory.swift  lådor, trådramar, måttetiketter.
│   └── FitSceneController.swift  FitResult → entiteter. Enda filen som känner
│                            till både affärslogik och RealityKit.
├── ViewModel/FitDemoModel.swift
├── Views/                   FitDemoView, FitBadgeView, CollisionAlertView,
│                            ProductPickerBar.
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

1. **Axelriktad geometri i motorn.** `PlaneFitter` hittar redan vridna ytors
   normaler korrekt (testat mot en 8°-vägg), men `NicheMeasurer` projicerar
   ner resultatet på X/Y/Z och `CollisionEngine` räknar AABB. För ett vridet kök
   blir måtten därför rätt medan krocklådorna hamnar snett. Fix: bygg ett
   ortonormalt system ur de passade normalerna och transformera produkt och
   hinder in i nischens lokala koordinater innan `intersection()` anropas — då
   gäller AABB-matematiken igen. OBB + SAT behövs först om nischens egna
   sidor inte är vinkelräta mot varandra (förekommer i äldre badrum).
2. **Krockfärgen sitter på överlappslådan, inte på produktmeshen.** Att färga
   just den del av meshen som skär in kräver en `CustomMaterial` med en Metal
   surface shader som klipper mot krockplanet. `PulseComponent`/`PulseSystem`
   kan behållas oförändrade — bara materialbytet i `PulseSystem.update` skrivs om.
3. **Lådor i stället för USDZ.** Produktkroppen är en grå låda i PIM-boxens
   mått. Riktiga modeller hängs in via `Product.modelAssetName` — men måtten
   måste fortsätta komma från PIM, aldrig från `visualBounds` på USDZ:en.
4. **Nischen ligger i scenens origo.** `Niche.center` finns redan; den fylls i
   från ankaret när RoomPlan kopplas in.

## Nästa steg

**Steg 2 — RoomPlan.** Lägg till en `RoomPlanNicheSource: NicheSource` som tar
en `CapturedRoom`, plockar `.wall`-ytor och `.storage`-objekt, mäter gapen och
returnerar `Niche` + `[Obstacle]`. Sätt `source: .roomPlan` så följer
mätosäkerheten med in i UI:t. Byt `content.camera` till `.worldTracking` och
hängn `controller.root` under en `AnchorEntity`. Ingen rad i `Engine/` behöver
ändras — det är hela poängen med `NicheSource`-protokollet.

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

Kör på ⌘U.
