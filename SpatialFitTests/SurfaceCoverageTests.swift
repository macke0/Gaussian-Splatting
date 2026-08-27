//
//  SurfaceCoverageTests.swift
//  SpatialFitTests
//
//  Täckningsmätningen avgör om kunden får veta att rummet har hål medan hen
//  fortfarande står i det. Går den fel åt det snälla hållet — påstår att allt
//  är fotograferat — är den värre än ingen mätning alls, för då slutar folk
//  titta efter. Därför testas den mot en rigg där facit är känt.
//

import Testing
import simd
@testable import SpatialFit

@Suite("Täckning av den uppmätta ytan")
struct SurfaceCoverageTests {

    // MARK: - Rigg

    static let intrinsics = simd_float3x3(SIMD3<Float>(500, 0, 0),
                                          SIMD3<Float>(0, 500, 0),
                                          SIMD3<Float>(320, 240, 1))

    /// Kamera i `position` som tittar rakt mot origo, ARKits konvention: den
    /// egna minus-Z-axeln är blickriktningen.
    static func camera(at position: SIMD3<Float>, id: Int) -> Keyframe {
        let back = simd_normalize(position)
        // Rakt uppifrån är blicken parallell med lodlinjen, och kryssprodukten
        // blir noll. Då duger vilken vågrät referens som helst.
        let reference: SIMD3<Float> = abs(back.y) > 0.99 ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
        let right = simd_normalize(simd_cross(reference, back))
        let up = simd_cross(back, right)

        var pose = matrix_identity_float4x4
        pose.columns.0 = SIMD4(right, 0)
        pose.columns.1 = SIMD4(up, 0)
        pose.columns.2 = SIMD4(back, 0)
        pose.columns.3 = SIMD4(position, 1)

        return Keyframe(id: id,
                        worldFromCamera: pose,
                        intrinsics: intrinsics,
                        imageSize: SIMD2(640, 480),
                        depthSize: SIMD2(0, 0))
    }

    /// En liten kvadrat i planet y = 0 med normalen uppåt, som ett bordsskiva.
    static let table = SceneMesh(positions: [SIMD3(-0.1, 0, -0.1), SIMD3(0.1, 0, -0.1),
                                             SIMD3(0.1, 0, 0.1), SIMD3(-0.1, 0, 0.1)],
                                 indices: [0, 1, 2, 0, 2, 3])

    static let noDepth: ViewSelection.DepthLookup = { _, _ in nil }

    // MARK: - Vinkelspannet

    @Test("Ett enda foto ger inget spann")
    func singleViewHasNoSpread() {
        #expect(SurfaceCoverage.spread(count: 1, sum: SIMD3(0, 0, 1)) == 0)
    }

    @Test("Två foton i rät vinkel mäts som nittio grader")
    func twoViewsGiveTheExactAngle() {
        let spread = SurfaceCoverage.spread(count: 2, sum: SIMD3(1, 0, 0) + SIMD3(0, 0, 1))
        #expect(abs(spread - 90) < 0.01)
    }

    @Test("Foton från nästan samma håll ger nästan inget spann")
    func nearlyIdenticalViewsCollapse() {
        let first = simd_normalize(SIMD3<Float>(0, 0, 1))
        let second = simd_normalize(SIMD3<Float>(0.05, 0, 1))
        #expect(SurfaceCoverage.spread(count: 2, sum: first + second) < 5)
    }

    // MARK: - Nivåerna

    @Test("Yta som inget foto ser räknas som saknad")
    func unseenSurfaceIsMissing() {
        // Kamerorna står under bordet och ser bara undersidan bortvänd från dem.
        let report = SurfaceCoverage.measure(mesh: Self.table,
                                             keyframes: [],
                                             depth: Self.noDepth)
        #expect(report.missingFraction == 1)
        #expect(report.faceLevels.allSatisfy { $0 == SurfaceCoverage.Level.missing.rawValue })
    }

    @Test("Yta sedd rakt uppifrån från ett enda håll räknas som tunn")
    func singleViewpointIsThin() {
        let report = SurfaceCoverage.measure(mesh: Self.table,
                                             keyframes: [Self.camera(at: SIMD3(0, 1.5, 0), id: 0)],
                                             depth: Self.noDepth)
        #expect(report.thinFraction == 1)
    }

    @Test("Yta sedd från två vitt skilda håll räknas som uppmätt")
    func twoWideViewpointsAreSolid() {
        let keyframes = [Self.camera(at: SIMD3(-1.2, 1.2, 0), id: 0),
                         Self.camera(at: SIMD3(1.2, 1.2, 0), id: 1)]
        let report = SurfaceCoverage.measure(mesh: Self.table,
                                             keyframes: keyframes,
                                             depth: Self.noDepth)
        #expect(report.solidFraction == 1)
    }

    @Test("Skymd yta räknas inte som fotograferad")
    func occludedSurfaceIsNotCounted() {
        let keyframes = [Self.camera(at: SIMD3(-1.2, 1.2, 0), id: 0),
                         Self.camera(at: SIMD3(1.2, 1.2, 0), id: 1)]
        // Djupkartan säger att allt kamerorna såg låg en halvmeter bort, alltså
        // långt framför bordet — något står emellan.
        let blocked: ViewSelection.DepthLookup = { _, _ in 0.5 }

        let report = SurfaceCoverage.measure(mesh: Self.table,
                                             keyframes: keyframes,
                                             depth: blocked)
        #expect(report.missingFraction == 1)
    }

    @Test("En triangel får sitt sämsta hörns nivå")
    func triangleTakesItsWorstCorner() {
        // Kvadraten sträcks ut så att bara ena halvan hamnar i bild.
        let mesh = SceneMesh(positions: [SIMD3(-0.1, 0, -0.1), SIMD3(0.1, 0, -0.1),
                                         SIMD3(0.1, 0, 0.1), SIMD3(-40, 0, 0.1)],
                             indices: [0, 1, 2, 0, 2, 3])
        let report = SurfaceCoverage.measure(mesh: mesh,
                                             keyframes: [Self.camera(at: SIMD3(0, 1.5, 0), id: 0)],
                                             depth: Self.noDepth)

        #expect(report.levels[3] == .missing)
        // Andra triangeln delar det bortdragna hörnet och ärver dess nivå.
        #expect(report.faceLevels[1] == SurfaceCoverage.Level.missing.rawValue)
    }

    @Test("Tom mesh ger en tom rapport i stället för att krascha")
    func emptyMeshIsHandled() {
        let report = SurfaceCoverage.measure(mesh: SceneMesh(),
                                             keyframes: [Self.camera(at: SIMD3(0, 1, 0), id: 0)],
                                             depth: Self.noDepth)
        #expect(report.levels.isEmpty)
        #expect(report.solidFraction == 0)
    }
}
