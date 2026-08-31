//
//  LiveCoverageTests.swift
//  SpatialFitTests
//
//  Kartan under skanningen är den enda återkoppling kunden får medan hen kan
//  göra något åt saken. Visar den grönt där täckningen är tunn slutar folk gå
//  runt möblerna, och då är kartan värre än ingen karta.
//

import Testing
import simd
@testable import SpatialFit

@Suite("Täckningen medan man filmar")
struct LiveCoverageTests {

    // MARK: - Rigg

    /// Djupkartans sida i riggen. Grövre än LiDAR:s 256×192, men fin nog att
    /// utvecklingen kan prövas mot en decimeter.
    static let side: Int32 = 64

    /// En kamera med känd hålkamera och nittio graders synfält.
    static func camera(at position: SIMD3<Float>, lookingAt target: SIMD3<Float>,
                       id: Int) -> Keyframe {
        let back = simd_normalize(position - target)
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
                        intrinsics: simd_float3x3(SIMD3<Float>(Float(side), 0, 0),
                                                  SIMD3<Float>(0, Float(side), 0),
                                                  SIMD3<Float>(Float(side) / 2, Float(side) / 2, 1)),
                        imageSize: SIMD2(Float(side), Float(side)),
                        depthSize: SIMD2(side, side))
    }

    /// Djupkarta där allt ligger på samma avstånd rakt fram.
    static func flatDepth(_ distance: Float) -> [Float] {
        [Float](repeating: distance, count: Int(side * side))
    }

    // MARK: - Utvecklingen av bilden

    @Test("En djuppunkt hamnar där kameran tittade")
    func unprojectionLandsWhereTheCameraLooked() {
        let keyframe = Self.camera(at: SIMD3(0, 0, 2), lookingAt: .zero, id: 0)
        let middle = Int(Self.side / 2) - 1
        let point = keyframe.unproject(depthColumn: middle, depthRow: middle, distance: 2)
        #expect(simd_distance(point, SIMD3(0, 0, 0)) < 0.05)
    }

    @Test("Utvecklingen är motsatsen till projektionen")
    func unprojectionInvertsProjection() {
        let keyframe = Self.camera(at: SIMD3(1, 0.5, 2), lookingAt: .zero, id: 0)
        let world = SIMD3<Float>(0.1, -0.2, 0.3)
        guard let projection = keyframe.project(world) else {
            Issue.record("punkten hamnade utanför bilden")
            return
        }
        let index = keyframe.depthIndex(for: projection.pixel)
        let back = keyframe.unproject(depthColumn: index % Int(Self.side),
                                      depthRow: index / Int(Self.side),
                                      distance: projection.depth)
        // En bildpunkt täcker drygt tre centimeter på det här avståndet.
        #expect(simd_distance(back, world) < 0.05)
    }

    // MARK: - Nivåerna

    @Test("Ingenting filmat ger en tom karta")
    func emptyCoverageHasNoMap() {
        #expect(LiveCoverage().map().tiles.isEmpty)
    }

    @Test("Ett enda foto ger tunn täckning, aldrig bred")
    func oneViewIsNeverSolid() {
        var coverage = LiveCoverage()
        coverage.add(Self.camera(at: SIMD3(0, 0, 2), lookingAt: .zero, id: 0),
                     depth: Self.flatDepth(2))
        #expect(!coverage.isEmpty)
        #expect(coverage.map().tiles.allSatisfy { $0.level == .thin })
    }

    @Test("Samma vägg sedd från två vitt skilda håll blir bred täckning")
    func twoWideViewsBecomeSolid() {
        var coverage = LiveCoverage()
        // Två kameror en meter isär i höjdled tittar ned på samma golvruta, så
        // riktningarna dit skiljer nittio grader.
        coverage.add(Self.camera(at: SIMD3(2, 1, 0), lookingAt: SIMD3(0, 1, 0), id: 0),
                     depth: Self.flatDepth(2))
        coverage.add(Self.camera(at: SIMD3(0, 1, 2), lookingAt: SIMD3(0, 1, 0), id: 1),
                     depth: Self.flatDepth(2))
        #expect(coverage.map().solidFraction > 0)
    }

    @Test("Djup utanför LiDAR:s räckvidd räknas inte")
    func absurdDepthIsIgnored() {
        var coverage = LiveCoverage()
        let keyframe = Self.camera(at: SIMD3(0, 0, 2), lookingAt: .zero, id: 0)
        coverage.add(keyframe, depth: Self.flatDepth(40))
        coverage.add(keyframe, depth: Self.flatDepth(0.05))
        coverage.add(keyframe, depth: [Float](repeating: .nan, count: Int(Self.side * Self.side)))
        #expect(coverage.isEmpty)
    }

    @Test("En djupkarta som inte stämmer med sin storlek avvisas")
    func truncatedDepthIsRejected() {
        var coverage = LiveCoverage()
        coverage.add(Self.camera(at: SIMD3(0, 0, 2), lookingAt: .zero, id: 0),
                     depth: [1, 1, 1])
        #expect(coverage.isEmpty)
    }
}
