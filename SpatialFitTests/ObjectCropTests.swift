//
//  ObjectCropTests.swift
//  SpatialFitTests
//
//  Vilket foto klipps pjäsen ur, och var?
//
//  Utsnittet är hela skillnaden mellan "ett kök" och "en rostfri induktionshäll"
//  när en bildmodell får titta. Räkningen är ren simd och testas mot en påhittad
//  kamerarigg, precis som vy-valet.
//

import Testing
import simd
@testable import SpatialFit

@Suite("Utsnitt kring en pjäs")
struct ObjectCropTests {

    /// Hålkameramatris: 640×480, brännvidd 500 px, bildcentrum i mitten.
    static let intrinsics = simd_float3x3(SIMD3<Float>(500, 0, 0),
                                          SIMD3<Float>(0, 500, 0),
                                          SIMD3<Float>(320, 240, 1))
    static let imageSize = SIMD2<Float>(640, 480)

    /// Kamera i `position`, tittande längs −Z.
    static func camera(at position: SIMD3<Float>, id: Int = 0) -> Keyframe {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(position, 1)
        return Keyframe(id: id,
                        worldFromCamera: pose,
                        intrinsics: intrinsics,
                        imageSize: imageSize,
                        depthSize: SIMD2(0, 0))
    }

    /// En spis: 0,6 × 0,9 × 0,6 m med mitten i `center`, axelriktad.
    static func stove(at center: SIMD3<Float>) -> RoomElement {
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(center, 1)
        return RoomElement(id: "spis",
                           category: .furniture,
                           transform: transform,
                           dimensions: SIMD3(0.6, 0.9, 0.6),
                           detail: "spis")
    }

    // MARK: - Hörnen

    @Test("En låda har åtta hörn, och de ligger symmetriskt kring mitten")
    func boxHasEightCorners() {
        let corners = ObjectCrop.corners(of: Self.stove(at: SIMD3(1, 2, 3)))

        #expect(corners.count == 8)
        let middle = corners.reduce(SIMD3<Float>.zero, +) / 8
        #expect(simd_distance(middle, SIMD3(1, 2, 3)) < 0.001)
    }

    // MARK: - Valet

    @Test("Utsnittet omsluter pjäsen och ligger i bilden")
    func cropSurroundsTheObject() throws {
        let keyframe = Self.camera(at: .zero)
        let crop = try #require(ObjectCrop.best(for: Self.stove(at: SIMD3(0, 0, -3)),
                                                in: [keyframe]))

        #expect(crop.keyframeID == 0)
        #expect(crop.origin.x >= 0)
        #expect(crop.origin.y >= 0)
        #expect(crop.origin.x + crop.size.x <= Self.imageSize.x)
        #expect(crop.origin.y + crop.size.y <= Self.imageSize.y)

        // Bildcentrum ska ligga inuti utsnittet: pjäsen står rakt framför.
        #expect(crop.origin.x < 320 && 320 < crop.origin.x + crop.size.x)
        #expect(crop.origin.y < 240 && 240 < crop.origin.y + crop.size.y)
    }

    @Test("Utsnittet är större än pjäsen, så modellen ser sammanhanget")
    func cropHasMargin() throws {
        let keyframe = Self.camera(at: .zero)
        let stove = Self.stove(at: SIMD3(0, 0, -3))
        let crop = try #require(ObjectCrop.best(for: stove, in: [keyframe]))

        // 0,6 m bred på 3 m avstånd med f = 500 blir 100 px. Marginalen lägger
        // till en femtedel åt vardera hållet.
        #expect(crop.size.x > 100)
        #expect(crop.size.x < 100 * 1.6)
    }

    @Test("Den närmaste bilden vinner, för den är den skarpaste")
    func closestPhotoWins() throws {
        let far = Self.camera(at: SIMD3(0, 0, 3), id: 0)
        let near = Self.camera(at: SIMD3(0, 0, 1), id: 1)
        let stove = Self.stove(at: SIMD3(0, 0, -2))

        let crop = try #require(ObjectCrop.best(for: stove, in: [far, near]))
        #expect(crop.keyframeID == 1)
    }

    @Test("En pjäs som bara syns till hälften klipps inte ut alls")
    func halfVisibleObjectIsSkipped() {
        // Spisen står långt ut åt sidan: några hörn hamnar utanför bildkanten.
        let keyframe = Self.camera(at: .zero)
        let stove = Self.stove(at: SIMD3(2.0, 0, -3))

        #expect(ObjectCrop.best(for: stove, in: [keyframe]) == nil)
    }

    @Test("En pjäs bakom kameran ger inget utsnitt")
    func objectBehindCameraIsSkipped() {
        let keyframe = Self.camera(at: .zero)
        #expect(ObjectCrop.best(for: Self.stove(at: SIMD3(0, 0, 3)), in: [keyframe]) == nil)
    }

    @Test("Utan foton finns inget att klippa ur")
    func noKeyframesGivesNothing() {
        #expect(ObjectCrop.best(for: Self.stove(at: .zero), in: []) == nil)
    }
}
