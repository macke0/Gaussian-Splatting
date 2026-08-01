//
//  CollisionEngineTests.swift
//  SpatialFitTests
//
//  Motorn är rent värdebaserad – därför kan hela affärsregeln testas utan
//  RealityKit, utan simulator och utan LiDAR. Det är själva poängen med
//  uppdelningen: när RoomPlan kopplas in i steg 2 byter vi bara ut nischen
//  i testerna nedan.
//

import Testing
@testable import SpatialFit

@Suite("Zonlogik")
struct FitZoneTests {

    private let source = MockKitchenNiche()

    private func evaluate(_ product: Product, policy: FitPolicy = .standard) -> FitResult {
        CollisionEngine.evaluate(product: product,
                                 niche: source.niche,
                                 obstacles: source.obstacles,
                                 policy: policy)
    }

    @Test("580 mm-spis i 600 mm-nisch ger grön zon")
    func productAIsGreen() {
        let fit = evaluate(ProductCatalog.productA)
        #expect(fit.zone == .green)
        #expect(fit.worstAxis.axis == .width)
        #expect(fit.worstAxis.clearanceMM == 20)
        #expect(fit.intersections.isEmpty)
        #expect(fit.recommendation == nil)
    }

    @Test("596 mm-spis i 600 mm-nisch ger gul zon utan krock")
    func productCIsYellow() {
        let fit = evaluate(ProductCatalog.productC)
        #expect(fit.zone == .yellow)
        #expect(fit.worstAxis.clearanceMM == 4)
        #expect(fit.intersections.isEmpty)
        #expect(fit.message.contains("kontrollmät"))
    }

    @Test("900 mm range cooker i 600 mm-nisch ger röd zon")
    func productBIsRed() {
        let fit = evaluate(ProductCatalog.productB)
        #expect(fit.zone == .red)
        #expect(fit.hasCollision)
        #expect(fit.worstAxis.axis == .width)
        #expect(fit.worstAxis.clearanceMM == -300)
        #expect(fit.worstAxis.overhangPerSideMM == 150)
        #expect(fit.message == "Produkten är +300 mm för bred för vald nisch")
    }

    @Test("Exakt 15 mm marginal är grön, 14,9 mm är gul")
    func thresholdBoundary() {
        var tight = ProductCatalog.productA
        tight.installationClearance = Dimensions3D(5, 0, 0)   // 20 - 5 = 15 mm kvar
        #expect(evaluate(tight).zone == .green)

        tight.installationClearance = Dimensions3D(5.1, 0, 0) // 14,9 mm kvar
        #expect(evaluate(tight).zone == .yellow)
    }

    @Test("Installationsmarginal räknas in i kravet")
    func installationClearanceCounts() {
        var withGap = ProductCatalog.productA
        withGap.installationClearance = Dimensions3D(0, 0, 60) // 60 mm ventilation bakom
        let fit = evaluate(withGap)
        #expect(fit.axes.first { $0.axis == .depth }?.requiredMM == 660)
        #expect(fit.zone == .red)
    }

    @Test("Skannerns mätosäkerhet kan skärpa gröngränsen")
    func scanToleranceRaisesThreshold() {
        let scanned = Niche(id: "scan", label: "Skannad nisch",
                            dimensions: source.niche.dimensions,
                            source: .roomPlan,          // ±15 mm
                            center: source.niche.center)

        var policy = FitPolicy.standard
        policy.addsScanTolerance = true

        // 20 mm marginal räcker mot 15 mm-gränsen, men inte mot 15+15.
        let fit = CollisionEngine.evaluate(product: ProductCatalog.productA,
                                           niche: scanned,
                                           obstacles: source.obstacles,
                                           policy: policy)
        #expect(fit.zone == .yellow)
    }
}

@Suite("Krockgeometri")
struct CollisionGeometryTests {

    private let source = MockKitchenNiche()

    @Test("Range cooker krockar med båda underskåpen, 150 mm per sida")
    func hitsBothCabinets() {
        let fit = CollisionEngine.evaluate(product: ProductCatalog.productB,
                                           niche: source.niche,
                                           obstacles: source.obstacles)

        #expect(fit.intersections.count == 2)
        #expect(Set(fit.intersections.map(\.id)) == ["cabinet-left", "cabinet-right"])

        for hit in fit.intersections {
            #expect(hit.obstacle.kind == .cabinet)
            #expect(abs(hit.penetrationMM - 150) < 0.5)
            #expect(hit.deepestAxis == .width)
        }
    }

    @Test("Produkt som står på golvet larmar inte mot golvet")
    func floorContactIsNotACollision() {
        let fit = CollisionEngine.evaluate(product: ProductCatalog.productA,
                                           niche: source.niche,
                                           obstacles: source.obstacles)
        #expect(!fit.intersections.contains { $0.obstacle.kind == .floor })
    }

    @Test("Tangerande ytor räknas inte som krock")
    func touchingIsNotIntersecting() {
        let a = BoxAABB(center: [0, 0, 0], size: [1, 1, 1])
        let b = BoxAABB(center: [1, 0, 0], size: [1, 1, 1])
        #expect(a.intersection(with: b) == nil)

        let c = BoxAABB(center: [0.99, 0, 0], size: [1, 1, 1])
        let overlap = a.intersection(with: c)
        #expect(overlap != nil)
        #expect(abs((overlap?.size.x ?? 0) - 0.01) < 0.0001)
    }

    @Test("Produkten placeras centrerad, golvställd och inskjuten mot bakkant")
    func placementIsInstallationRealistic() {
        let placement = CollisionEngine.placement(for: ProductCatalog.productA,
                                                  in: source.niche)
        #expect(placement.center.x == source.niche.center.x)
        #expect(abs(placement.minCorner.y - source.niche.floorLevel) < 0.0001)
        #expect(abs(placement.minCorner.z - source.niche.backPlane) < 0.0001)
    }
}
