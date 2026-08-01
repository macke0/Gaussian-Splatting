# SpatialFit — Steg 1: MVP av kollisionsmotorn

Proof-of-concept för den geometriska passformsmotorn: en mockad köksnisch på
600 mm, en produktväljare i botten, och zonlogik (🟢/🟡/🔴) med pulserande
krockvolymer och varningsmodal.

Scenen körs med **virtuell kamera**, inte AR-passthrough. Det gör att demot
fungerar i simulatorn och på iPhones utan LiDAR — och att kollisionsmotorn kan
demonstreras för en kedja utan att någon behöver skanna ett rum först.

## Kom igång

1. Xcode → *File ▸ New ▸ Project ▸ iOS ▸ App*
   - Product Name: `SpatialFit`
   - Interface: **SwiftUI**, Language: **Swift**
   - Testing System: **Swift Testing**
2. Radera den genererade `ContentView.swift` och `SpatialFitApp.swift`.
3. Dra in mapparna `SpatialFit/` och `SpatialFitTests/` i projektet
   (*Create groups*, target `SpatialFit` respektive `SpatialFitTests`).
4. Deployment target: **iOS 18.0** (`RealityView`, `MagnifyGesture`,
   `@Observable`, `symbolEffect`).
5. Kör på simulator eller enhet.

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

1. **Axelriktad geometri.** Allt är AABB. Riktiga RoomPlan-väggar är roterade i
   världsrymden. Fix i steg 2: transformera produkt och hinder in i nischens
   lokala koordinatsystem innan `intersection()` anropas — då gäller
   AABB-matematiken igen. Alternativt OBB + SAT om vi behöver hantera
   ej-vinkelräta hörn (vanligt i äldre badrum).
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

**Steg 3 — Precision.** Temporal averaging (Kalman) över nischbredden mellan
frames, plus "smart edge snap" mot visuella kanter från kamerabilden. Källan
uppgraderas till `.lidarRefined` (±3 mm) vilket automatiskt skärper zonerna om
`addsScanTolerance` slås på.

**Steg 4 — Surface replacement.** Kakel/tapet på `.wall`-ytor:
`MeshResource.generatePlane` från `surface.dimensions`, 2 mm offset längs
väggnormalen mot z-fighting, och UV-repeat = väggmått / plattmått så att
150 mm-plattor behåller sin fysiska skala. Detta hör hemma i en egen
`SurfaceReplacement`-modul bredvid `RealityKit/` och rör inte kollisionsmotorn.

## Tester

`SpatialFitTests/CollisionEngineTests.swift` täcker zongränserna,
installationsmarginal, mätosäkerhet, krockgeometrin (2 träffar × 150 mm) och
att tangerande ytor inte larmar. Testerna importerar varken RealityKit eller
SwiftUI — kör på ⌘U utan simulatorstart.
