# SpatialFit

iOS/iPadOS-app (Swift, SwiftUI, RealityKit, RoomPlan) som säljs B2B till bygg-,
köks- och badrumskedjor. Den ska stoppa returer orsakade av "spatial mismatch":
produkten passar inte i nischen. Kärnan är en geometrisk kollisionsmotor med
grön/gul/röd-zonlogik, inte en möbelutplacerare.

Prototypstadium. Se `README.md` för arkitektur, kända begränsningar och
de fyra planerade stegen.

## Språk

Svenska i UI-strängar, kodkommentarer och commit-meddelanden. Engelska i
API-namn (typer, funktioner, properties).

## Regler som inte får brytas

**Enheter.** Domänen räknar i millimeter (`Double`). RealityKit räknar i meter
(`Float`). Konvertering sker uteslutande via `Units` i `Model/Units.swift`.
Dividera aldrig med 1000 någon annanstans.

**PIM-måtten är sanningen.** Produktens bounding box kommer från PIM-systemet,
aldrig från `visualBounds` på en USDZ-modell. USDZ-filer är approximativa; det
är PIM-måttet kunden reklamerar mot.

**Lagerindelning.** `Model/` och `Engine/` får aldrig importera RealityKit,
SwiftUI eller UIKit — bara `Foundation` och `simd`. `FitSceneController` är den
enda filen som känner till både affärslogik och RealityKit. Beroenden går bara
nedåt: Model → Engine → RealityKit → Views.

**Ny mätdatakälla = ny `NicheSource`.** RoomPlan, manuell inmatning och
LiDAR-förfining implementerar protokollet i `Model/Niche.swift`. Ingen rad i
`Engine/` ska behöva ändras för att byta datakälla. Om en ändring i `Engine/`
känns nödvändig för att koppla in RoomPlan är abstraktionen fel — säg till i
stället för att kringgå den.

**Zonlogiken är en affärsregel.** Trösklar ändras via `FitPolicy`, aldrig genom
hårdkodade tal i motorn eller vyerna. Kedjor kommer vilja ha olika marginaler.

## Bygga och testa (macOS)

```bash
xcodebuild -scheme SpatialFit -destination 'platform=iOS Simulator,name=iPhone 16' build
```

```bash
xcodebuild test -scheme SpatialFit -destination 'platform=iOS Simulator,name=iPhone 16'
```

Testerna i `SpatialFitTests/` importerar varken RealityKit eller SwiftUI. När du
ändrar zonlogik eller krockgeometri: uppdatera testerna i samma commit.

Deployment target är iOS 18.0 (`RealityView`, `MagnifyGesture`, `@Observable`,
`symbolEffect`).

## Kontext

Den ursprungliga tekniska specen kom ur en brainstorm och är riktning, inte
kravlista. Föreslå gärna bättre lösningar än de som står där — särskilt kring
mätprecision och shaders — men flagga avvikelsen i stället för att tyst byta väg.
