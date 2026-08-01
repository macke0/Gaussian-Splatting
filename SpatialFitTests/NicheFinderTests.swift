//
//  NicheFinderTests.swift
//  SpatialFitTests
//
//  Ett syntetiskt kök med känt facit, byggt VRIDET i världen.
//
//  Det är hela testets idé. Ett kök som råkar ligga längs X-axeln bevisar
//  ingenting – det är exakt det fallet där den gamla axelriktade koden också
//  fungerade. Rummet här står 31° snett och sitter 2,5 m från origo, och
//  kraven är desamma: 600 × 900 × 650 mm på under en millimeter, och krock-
//  lådorna på rätt plats.
//

import Testing
import Foundation
import simd
@testable import SpatialFit

// MARK: - Rumsbyggare

/// Bygger ett kök i valfri vridning: bakvägg, golv och två underskåp som
/// flankerar ett gap. Allt uttryckt som RoomPlan hade uttryckt det – lådor
/// med egen transform, inte axelriktade mått.
private struct SyntheticKitchen {

    /// Väggens riktning i horisontalplanet.
    let rotation: Float
    /// Var väggens mittpunkt sitter i världen.
    let anchor: SIMD3<Float>

    let gapMM: Double
    let cabinetWidthMM: Double
    let cabinetHeightMM: Double
    let cabinetDepthMM: Double

    init(rotation: Float = .pi * 31 / 180,
         anchor: SIMD3<Float> = SIMD3(2.5, 0, -1.75),
         gapMM: Double = 600,
         cabinetWidthMM: Double = 600,
         cabinetHeightMM: Double = 900,
         cabinetDepthMM: Double = 650) {
        self.rotation = rotation
        self.anchor = anchor
        self.gapMM = gapMM
        self.cabinetWidthMM = cabinetWidthMM
        self.cabinetHeightMM = cabinetHeightMM
        self.cabinetDepthMM = cabinetDepthMM
    }

    /// Väggens bas: längs, upp, ut i rummet.
    var along: SIMD3<Float> { SIMD3(cos(rotation), 0, sin(rotation)) }
    var outward: SIMD3<Float> { simd_cross(along, SIMD3(0, 1, 0)) }

    /// Punkt uttryckt i väggens system → världen.
    func world(along a: Float, outward o: Float, height y: Float) -> SIMD3<Float> {
        anchor + along * a + outward * o + SIMD3(0, y, 0)
    }

    /// Transform med väggens orientering, placerad i en punkt.
    func transform(at position: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(along, 0),
                                SIMD4(0, 1, 0, 0),
                                SIMD4(outward, 0),
                                SIMD4(position, 1)))
    }

    var elements: [RoomElement] {
        let gap = gapMM.asMeters
        let cw = cabinetWidthMM.asMeters
        let ch = cabinetHeightMM.asMeters
        let cd = cabinetDepthMM.asMeters

        // Skåpens mittpunkter: halva gapet ut från väggmitten, plus halva skåpet.
        func cabinet(_ id: String, sign: Float) -> RoomElement {
            let center = world(along: sign * (gap / 2 + cw / 2), outward: cd / 2, height: ch / 2)
            return RoomElement(id: id,
                               category: .furniture,
                               transform: transform(at: center),
                               dimensions: SIMD3(cw, ch, cd),
                               detail: "skåp")
        }

        // RoomPlan-ytor är plan: tjockleken ligger i lokala Z och är noll.
        let wall = RoomElement(id: "wall",
                               category: .wall,
                               transform: transform(at: world(along: 0, outward: 0, height: 1.3)),
                               dimensions: SIMD3(4.0, 2.6, 0),
                               detail: "vägg")

        // Golvets normal ligger i dess lokala Z, precis som RoomPlan levererar.
        let floorTransform = simd_float4x4(columns: (SIMD4(along, 0),
                                                    SIMD4(outward, 0),
                                                    SIMD4(0, 1, 0, 0),
                                                    SIMD4(world(along: 0, outward: 1.5, height: 0), 1)))
        let floor = RoomElement(id: "floor",
                                category: .floor,
                                transform: floorTransform,
                                dimensions: SIMD3(4.0, 3.0, 0),
                                detail: "golv")

        return [wall, floor, cabinet("cabinet-left", sign: -1), cabinet("cabinet-right", sign: +1)]
    }
}

@Suite("Nischsökning i skannat rum")
struct NicheFinderTests {

    @Test("Ett vridet kök ger rätt nischmått ändå")
    func findsNicheInRotatedRoom() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)

        #expect(abs(found.niche.dimensions.width - 600) < 1.0)
        #expect(abs(found.niche.dimensions.height - 900) < 1.0)
        #expect(abs(found.niche.dimensions.depth - 650) < 1.0)
        #expect(found.niche.source == .roomPlan)
    }

    @Test("Måtten är oberoende av hur rummet ligger i världen",
          arguments: [Float(0), 0.4, 1.1, 2.7, -1.9, .pi])
    func measurementIsRotationInvariant(rotation: Float) throws {
        let kitchen = SyntheticKitchen(rotation: rotation,
                                       anchor: SIMD3(-4.2, 0, 6.8))
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)

        #expect(abs(found.niche.dimensions.width - 600) < 1.0)
        #expect(abs(found.niche.dimensions.height - 900) < 1.0)
        #expect(abs(found.niche.dimensions.depth - 650) < 1.0)
    }

    @Test("Nischens origo hamnar i golvhöjd, mitt i öppningen")
    func nicheOriginSitsOnTheFloorBetweenTheCabinets() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)

        // Facit: mitt på väggen, halva nischdjupet ut, i golvhöjd.
        let expected = kitchen.world(along: 0, outward: 0.650 / 2, height: 0)
        let origin = found.worldFromNiche.columns.3
        #expect(simd_distance(SIMD3(origin.x, origin.y, origin.z), expected) < 0.001)

        // Mockens konvention: nischens mitt ligger på halva höjden rakt över
        // origo, så CollisionEngine.placement fungerar oförändrad.
        #expect(abs(found.niche.center.x) < 0.001)
        #expect(abs(found.niche.center.z) < 0.001)
        #expect(abs(found.niche.floorLevel) < 0.001)
    }

    @Test("Transformen är en ren rotation, ingen skalning eller spegling")
    func transformIsOrthonormal() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)
        let m = found.worldFromNiche

        let x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
        let y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
        let z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)

        #expect(abs(simd_length(x) - 1) < 1e-5)
        #expect(abs(simd_length(y) - 1) < 1e-5)
        #expect(abs(simd_length(z) - 1) < 1e-5)
        #expect(abs(simd_dot(x, y)) < 1e-5)
        #expect(abs(simd_dot(y, z)) < 1e-5)
        #expect(abs(simd_dot(x, z)) < 1e-5)
        // Högerorienterad: annars hamnar krocklådorna spegelvänt.
        #expect(simd_distance(simd_cross(x, y), z) < 1e-5)
    }

    @Test("Skåpen blir hinder som ligger kant i kant med nischen")
    func cabinetsBecomeObstaclesFlushWithTheNiche() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)

        let left = try #require(found.obstacles.first { $0.id == "cabinet-left" })
        let right = try #require(found.obstacles.first { $0.id == "cabinet-right" })

        // Skåpens innerkanter ÄR nischens sidor.
        #expect(abs(left.box.maxCorner.x - (-0.300)) < 0.001)
        #expect(abs(right.box.minCorner.x - 0.300) < 0.001)
        #expect(left.kind == .cabinet)
    }

    @Test("Golvet följer med men får aldrig larma som krock")
    func floorIsNotCollidable() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)
        let floor = try #require(found.obstacles.first { $0.id == "floor" })

        #expect(floor.kind == .floor)
        #expect(floor.isCollidable == false)
        // Överytan ska ligga i nischens golvnivå, inte mitt i den.
        #expect(abs(floor.box.maxCorner.y) < 0.001)
    }

    @Test("Väggen får volym så den kan krocka, men behåller sitt läge")
    func wallKeepsItsMeasuredFace() throws {
        let kitchen = SyntheticKitchen()
        let found = try #require(NicheFinder.niches(in: kitchen.elements).first)
        let wall = try #require(found.obstacles.first { $0.id == "wall" })

        #expect(wall.box.size.z >= 0.010)
        // Framsidan ligger kvar vid nischens bakkant.
        #expect(abs(wall.box.maxCorner.z - (-0.325)) < 0.001)
    }

    // MARK: - Hela vägen genom motorn

    @Test("Ett skannat, vridet kök går rakt in i kollisionsmotorn")
    func scannedRoomFeedsTheCollisionEngine() throws {
        let kitchen = SyntheticKitchen()
        let source = try #require(NicheFinder.niches(in: kitchen.elements).first)

        let green = CollisionEngine.evaluate(product: ProductCatalog.productA,
                                             niche: source.niche,
                                             obstacles: source.obstacles)
        #expect(green.zone == .green)
        #expect(green.intersections.isEmpty)

        let red = CollisionEngine.evaluate(product: ProductCatalog.productB,
                                           niche: source.niche,
                                           obstacles: source.obstacles)
        #expect(red.zone == .red)
        // 900 mm i 600 mm-nisch: 150 mm in i vardera skåp.
        #expect(red.intersections.count == 2)
        for hit in red.intersections {
            #expect(abs(hit.penetrationMM - 150) < 1.0)
        }
    }

    // MARK: - När det inte finns någon nisch

    @Test("Ett gap med en dörr i är ingen nisch")
    func doorwayIsNotANiche() {
        let kitchen = SyntheticKitchen()
        let door = RoomElement(id: "door",
                               category: .opening,
                               transform: kitchen.transform(at: kitchen.world(along: 0, outward: 0, height: 1.0)),
                               dimensions: SIMD3(0.9, 2.0, 0),
                               detail: "dörr")

        #expect(NicheFinder.niches(in: kitchen.elements + [door]).isEmpty)
    }

    @Test("En köksö räknas inte som nischsida")
    func islandAwayFromTheWallIsIgnored() {
        let kitchen = SyntheticKitchen()
        let island = RoomElement(id: "island",
                                 category: .furniture,
                                 transform: kitchen.transform(at: kitchen.world(along: 0, outward: 1.6, height: 0.45)),
                                 dimensions: SIMD3(1.2, 0.9, 0.7),
                                 detail: "skåp")

        // Ön står 1,6 m ut i rummet. Gapet mellan den och skåpsraden är ingen
        // nisch, och den får inte heller störa den riktiga nischen.
        let found = NicheFinder.niches(in: kitchen.elements + [island])
        #expect(found.count == 1)
        #expect(abs(found[0].niche.dimensions.width - 600) < 1.0)
    }

    @Test("Ett tomt rum ger inga nischer, inte en påhittad")
    func emptyRoomYieldsNothing() {
        let kitchen = SyntheticKitchen()
        let bare = kitchen.elements.filter { $0.category != .furniture }
        #expect(NicheFinder.niches(in: bare).isEmpty)
    }

    @Test("Ett gap på 120 mm är en springa, inte en nisch")
    func slitBetweenCabinetsIsRejected() {
        let kitchen = SyntheticKitchen(gapMM: 120)
        #expect(NicheFinder.niches(in: kitchen.elements).isEmpty)
    }
}
