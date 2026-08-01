//
//  NicheMeasurementTests.swift
//  SpatialFitTests
//
//  Hela mätkedjan är värdebaserad: [DepthSample] in, mått + osäkerhet ut.
//  Därför går den att testa mot ett SYNTETISKT punktmoln där facit är känt –
//  utan LiDAR, utan enhet, utan att åka till en butik och hålla i en tumstock.
//
//  Bruset här (σ = 10 mm) är medvetet i värsta laget för iPhone-LiDAR på en
//  meters håll. Klarar mätningen det klarar den ett kök.
//

import Testing
import simd
@testable import SpatialFit

// MARK: - Syntetiskt punktmoln

/// Deterministisk brusgenerator. Tester som ibland faller är värdelösa,
/// särskilt för statistik – därför egen seedad RNG i stället för `Double.random`.
private struct SeededNoise {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    private mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    private mutating func uniform() -> Float {
        Float(next() >> 11) / Float(1 << 53)
    }

    /// Box-Muller: normalfördelat brus med given standardavvikelse.
    mutating func gaussian(sigma: Float) -> Float {
        let u1 = max(uniform(), 1e-7)
        let u2 = uniform()
        return sigma * (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// En rektangulär yta med brus längs sin normal.
private func surface(origin: SIMD3<Float>,
                     spanA: SIMD3<Float>,
                     spanB: SIMD3<Float>,
                     normal: SIMD3<Float>,
                     samplesPerSide: Int,
                     noiseSigma: Float,
                     confidence: Float = 1,
                     noise: inout SeededNoise) -> [DepthSample] {
    var result: [DepthSample] = []
    let unitNormal = simd_normalize(normal)
    for i in 0..<samplesPerSide {
        for j in 0..<samplesPerSide {
            let a = Float(i) / Float(samplesPerSide - 1)
            let b = Float(j) / Float(samplesPerSide - 1)
            let point = origin + spanA * a + spanB * b
                + unitNormal * noise.gaussian(sigma: noiseSigma)
            result.append(DepthSample(position: point, confidence: confidence))
        }
    }
    return result
}

/// En 600 × 900 × 650 mm nisch mellan två underskåp, skannad med brus.
/// Nischens fria volym: x ∈ [-0,300, 0,300], y ∈ [0, 0,900], z ∈ [-0,325, 0,325].
private func scannedKitchenNiche(noiseSigma: Float = 0.010,
                                 samplesPerSide: Int = 40,
                                 seed: UInt64 = 42) -> [DepthSample] {
    var noise = SeededNoise(seed: seed)
    var cloud: [DepthSample] = []

    let height: Float = 0.900
    let halfWidth: Float = 0.300
    let halfDepth: Float = 0.325

    // Vänster och höger skåpsida (normaler inåt = ±X)
    for sign in [Float(-1), Float(1)] {
        cloud += surface(origin: SIMD3(sign * halfWidth, 0, -halfDepth),
                         spanA: SIMD3(0, height, 0),
                         spanB: SIMD3(0, 0, 2 * halfDepth),
                         normal: SIMD3(-sign, 0, 0),
                         samplesPerSide: samplesPerSide,
                         noiseSigma: noiseSigma,
                         noise: &noise)
    }

    // Golv och undersida bänkskiva (normaler inåt = ±Y)
    for (y, normalY) in [(Float(0), Float(1)), (height, Float(-1))] {
        cloud += surface(origin: SIMD3(-halfWidth, y, -halfDepth),
                         spanA: SIMD3(2 * halfWidth, 0, 0),
                         spanB: SIMD3(0, 0, 2 * halfDepth),
                         normal: SIMD3(0, normalY, 0),
                         samplesPerSide: samplesPerSide,
                         noiseSigma: noiseSigma,
                         noise: &noise)
    }

    // Bakvägg och skåpens framkant (normaler inåt = ±Z)
    for (z, normalZ) in [(-halfDepth, Float(1)), (halfDepth, Float(-1))] {
        cloud += surface(origin: SIMD3(-halfWidth, 0, z),
                         spanA: SIMD3(2 * halfWidth, 0, 0),
                         spanB: SIMD3(0, height, 0),
                         normal: SIMD3(0, 0, normalZ),
                         samplesPerSide: samplesPerSide,
                         noiseSigma: noiseSigma,
                         noise: &noise)
    }

    return cloud
}

/// Grovt utgångsläge, medvetet 10–20 mm fel på varje sida – ungefär vad
/// RoomPlan eller en användarmarkering levererar.
private let seedBox = BoxAABB(center: SIMD3(0.008, 0.455, -0.004),
                              size: SIMD3(0.620, 0.918, 0.664))

// MARK: - Planpassning

@Suite("Planpassning")
struct PlaneFitTests {

    @Test("Ett plan passas rätt trots 10 mm brus per punkt")
    func recoversPlanePosition() {
        var noise = SeededNoise(seed: 7)
        let points = surface(origin: SIMD3(-0.3, 0, -0.3),
                             spanA: SIMD3(0.6, 0, 0),
                             spanB: SIMD3(0, 0, 0.6),
                             normal: SIMD3(0, 1, 0),
                             samplesPerSide: 40,
                             noiseSigma: 0.010,
                             noise: &noise)

        let fit = PlaneFitter.fit(points,
                                  seed: Plane(normal: SIMD3(0, 1, 0), through: SIMD3(0, 0.012, 0)))
        let plane = try! #require(fit)

        // Planet ska ligga på y = 0, dvs. offset ≈ 0.
        #expect(abs(Double(plane.plane.offset).magnitude * 1000) < 1.0)
        #expect(simd_dot(plane.plane.normal, SIMD3<Float>(0, 1, 0)) > 0.999)
    }

    @Test("Medelfelet är mycket mindre än punktbruset – det är hela poängen")
    func standardErrorShrinksWithSampleCount() {
        var noise = SeededNoise(seed: 11)
        let points = surface(origin: SIMD3(-0.3, 0, -0.3),
                             spanA: SIMD3(0.6, 0, 0),
                             spanB: SIMD3(0, 0, 0.6),
                             normal: SIMD3(0, 1, 0),
                             samplesPerSide: 40,   // 1 600 punkter
                             noiseSigma: 0.010,
                             noise: &noise)

        let fit = try! #require(PlaneFitter.fit(points,
                                                seed: Plane(normal: SIMD3(0, 1, 0),
                                                            through: .zero)))

        // Spridningen ska spegla bruset (robust förkastning kapar svansarna,
        // så den hamnar strax under 10 mm).
        #expect(fit.rmsResidualMM > 5)
        #expect(fit.rmsResidualMM < 12)

        // Men LÄGET är känt tiopotenser bättre: σ/√n ≈ 10/√1600 ≈ 0,25 mm.
        #expect(fit.standardErrorMM < 0.5)
        #expect(fit.inlierCount > 1200)
    }

    @Test("En vriden vägg får rätt normal")
    func recoversTiltedNormal() {
        var noise = SeededNoise(seed: 3)
        // 8° vriden vägg – vanligt i äldre hus, och det som gör ren AABB fel.
        let angle = Float(8 * Float.pi / 180)
        let normal = SIMD3<Float>(cos(angle), 0, sin(angle))
        let along = SIMD3<Float>(-sin(angle), 0, cos(angle))

        let points = surface(origin: SIMD3(-0.3, 0, 0) - along * 0.3,
                             spanA: along * 0.6,
                             spanB: SIMD3(0, 0.9, 0),
                             normal: normal,
                             samplesPerSide: 40,
                             noiseSigma: 0.008,
                             noise: &noise)

        let fit = try! #require(PlaneFitter.fit(points,
                                                seed: Plane(normal: SIMD3(1, 0, 0),
                                                            through: SIMD3(-0.3, 0, 0))))

        // Normalen ska ha hittat de 8 graderna, inte fastnat i utgångsgissningen.
        let recovered = acos(min(1, simd_dot(fit.plane.normal, normal))) * 180 / .pi
        #expect(recovered < 0.5)
    }

    @Test("En yta som inte finns i molnet ger nil, inte ett påhittat mått")
    func missingSurfaceFails() {
        var noise = SeededNoise(seed: 5)
        let points = surface(origin: SIMD3(-0.3, 0, -0.3),
                             spanA: SIMD3(0.6, 0, 0),
                             spanB: SIMD3(0, 0, 0.6),
                             normal: SIMD3(0, 1, 0),
                             samplesPerSide: 40,
                             noiseSigma: 0.010,
                             noise: &noise)

        // Leta efter en vägg en halvmeter bort från allt vi har punkter på.
        let fit = PlaneFitter.fit(points,
                                  seed: Plane(normal: SIMD3(1, 0, 0),
                                              through: SIMD3(1.5, 0, 0)))
        #expect(fit == nil)
    }

    @Test("Lågkonfidenta punkter tas inte med")
    func lowConfidenceIsExcluded() {
        var noise = SeededNoise(seed: 9)
        let good = surface(origin: SIMD3(-0.3, 0, -0.3),
                           spanA: SIMD3(0.6, 0, 0),
                           spanB: SIMD3(0, 0, 0.6),
                           normal: SIMD3(0, 1, 0),
                           samplesPerSide: 30,
                           noiseSigma: 0.005,
                           confidence: 1,
                           noise: &noise)
        // Blank vitvarufront 30 mm fel, men markerad som osäker av ARKit.
        let junk = surface(origin: SIMD3(-0.3, 0.030, -0.3),
                           spanA: SIMD3(0.6, 0, 0),
                           spanB: SIMD3(0, 0, 0.6),
                           normal: SIMD3(0, 1, 0),
                           samplesPerSide: 30,
                           noiseSigma: 0.002,
                           confidence: 0,
                           noise: &noise)

        let fit = try! #require(PlaneFitter.fit(good + junk,
                                                seed: Plane(normal: SIMD3(0, 1, 0),
                                                            through: .zero)))
        #expect(abs(Double(fit.plane.offset) * 1000) < 1.0)
    }
}

// MARK: - Nischmätning

@Suite("Nischmätning")
struct NicheMeasurerTests {

    @Test("600 mm-nisch mäts på under 2 mm trots 10 mm punktbrus")
    func measuresWidthAccurately() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)
        let width = try! #require(measurement.measurement(for: .width))

        #expect(width.isMeasured)
        #expect(abs(width.extentMM - 600) < 2.0)
        #expect(abs(measurement.dimensions.height - 900) < 2.0)
        #expect(abs(measurement.dimensions.depth - 650) < 2.0)
    }

    @Test("Precisionen håller över flera brusutfall, inte bara ett lyckligt",
          arguments: [1, 2, 3, 4, 5] as [UInt64])
    func measuresAccuratelyAcrossNoiseSeeds(noiseSeed: UInt64) {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(seed: noiseSeed),
                                                seed: seedBox)

        #expect(abs(measurement.dimensions.width - 600) < 2.0)
        #expect(abs(measurement.dimensions.height - 900) < 2.0)
        #expect(abs(measurement.dimensions.depth - 650) < 2.0)
    }

    @Test("Osäkerheten hamnar i millimeterklassen, inte centimeterklassen")
    func reportsMillimeterTolerance() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)

        #expect(measurement.isFullyMeasured)
        #expect(measurement.toleranceMM < 3.0)
        // Men aldrig under golvet – σ/√n går mot noll, verkligheten gör inte det.
        #expect(measurement.toleranceMM >= NicheMeasurer.systematicFloorMM)
    }

    @Test("Ytans ojämnhet rapporteras separat från lägets osäkerhet")
    func roughnessAndUncertaintyAreDifferentNumbers() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)
        let width = try! #require(measurement.measurement(for: .width))

        // Spridningen speglar bruset per punkt …
        #expect(width.surfaceRoughnessMM > 5)
        // … men måttet är mycket säkrare än så.
        #expect(width.uncertaintyMM < width.surfaceRoughnessMM / 3)
    }

    @Test("Nischens mittpunkt hittas trots skevt utgångsläge")
    func recentersOnMeasuredSurfaces() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)

        #expect(abs(measurement.center.x) < 0.002)
        #expect(abs(measurement.center.y - 0.450) < 0.002)
        #expect(abs(measurement.center.z) < 0.002)
    }

    @Test("Omätbar axel faller tillbaka på utgångsläget och flaggas")
    func unmeasurableAxisFallsBack() {
        // Ta bort djupytorna ur molnet genom att bara mäta bredd och höjd.
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(),
                                                seed: seedBox,
                                                axes: [.width, .height])
        let depth = try! #require(measurement.measurement(for: .depth))

        #expect(!depth.isMeasured)
        #expect(depth.extentMM == seedBox.dimensions.depth)
        #expect(depth.uncertaintyMM == MeasurementSource.roomPlan.nominalToleranceMM)
        #expect(!measurement.isFullyMeasured)
        // Sämsta axeln styr helheten – annars vore osäkerheten en lögn.
        #expect(measurement.toleranceMM == 15)
    }

    @Test("En helt uppmätt nisch blir lidarRefined och bär sin egen tolerans")
    func producesNicheWithMeasuredTolerance() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)
        let niche = measurement.niche(id: "scan-1", label: "Skannad nisch")

        #expect(niche.source == .lidarRefined)
        #expect(niche.toleranceMM == measurement.toleranceMM)
        // Den uppmätta toleransen ska slå källans schablon på ±3 mm.
        #expect(niche.toleranceMM != MeasurementSource.lidarRefined.nominalToleranceMM)
    }

    @Test("Uppmätt nisch går rakt in i kollisionsmotorn")
    func feedsTheCollisionEngine() {
        let measurement = NicheMeasurer.measure(scannedKitchenNiche(), seed: seedBox)
        let niche = measurement.niche(id: "scan-1", label: "Skannad nisch")

        var policy = FitPolicy.standard
        policy.addsScanTolerance = true

        // 580 mm-spisen har 20 mm marginal. Med en uppmätt osäkerhet på ~1 mm
        // räcker det till grönt – med RoomPlans schablon på ±15 mm hade den
        // blivit gul. Det är hela vinsten med att mäta ytor i stället för punkter.
        let fit = CollisionEngine.evaluate(product: ProductCatalog.productA,
                                           niche: niche,
                                           obstacles: [],
                                           policy: policy)
        #expect(fit.zone == .green)
    }
}
