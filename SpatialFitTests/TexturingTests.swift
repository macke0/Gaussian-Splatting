//
//  TexturingTests.swift
//  SpatialFitTests
//
//  Projektionen och vy-valet är den del av textureringen som avgör om rummet
//  blir fotoidentiskt eller utsmetat. Båda är ren matematik och testas därför
//  utan kamera, mot en påhittad kamerarigg.
//

import Testing
import simd
@testable import SpatialFit

@Suite("Fotografisk texturering")
struct TexturingTests {

    // MARK: - Rigg

    /// Hålkameramatris: 640×480, brännvidd 500 px, bildcentrum i mitten.
    static let intrinsics = simd_float3x3(SIMD3<Float>(500, 0, 0),
                                          SIMD3<Float>(0, 500, 0),
                                          SIMD3<Float>(320, 240, 1))
    static let imageSize = SIMD2<Float>(640, 480)

    /// Kamera som tittar längs −Z, ARKits konvention.
    static func camera(at position: SIMD3<Float>,
                       id: Int = 0,
                       depthSize: SIMD2<Int32> = SIMD2(0, 0)) -> Keyframe {
        var pose = matrix_identity_float4x4
        pose.columns.3 = SIMD4(position, 1)
        return Keyframe(id: id,
                        worldFromCamera: pose,
                        intrinsics: intrinsics,
                        imageSize: imageSize,
                        depthSize: depthSize)
    }

    /// Liten triangel i planet z = −2, med normalen mot kameran i origo.
    static let facingTriangle = ViewSelection.Triangle(SIMD3(-0.2, -0.2, -2),
                                                       SIMD3(0.2, -0.2, -2),
                                                       SIMD3(0, 0.2, -2))

    static let noDepth: ViewSelection.DepthLookup = { _, _ in nil }

    // MARK: - Projektion

    @Test("En punkt rakt framför kameran hamnar i bildens mitt")
    func centreProjectsToPrincipalPoint() throws {
        let keyframe = Self.camera(at: .zero)
        let projection = try #require(keyframe.project(SIMD3(0, 0, -2)))

        #expect(abs(projection.pixel.x - 320) < 0.001)
        #expect(abs(projection.pixel.y - 240) < 0.001)
        #expect(abs(projection.depth - 2) < 0.001)
    }

    @Test("Höger i världen blir höger i bilden, upp blir uppåt")
    func projectionKeepsOrientation() throws {
        let keyframe = Self.camera(at: .zero)
        let right = try #require(keyframe.project(SIMD3(0.5, 0, -2)))
        let up = try #require(keyframe.project(SIMD3(0, 0.5, -2)))

        #expect(right.pixel.x > 320)
        #expect(abs(right.pixel.y - 240) < 0.001)
        // Radnumret växer nedåt i bilden, så uppåt i världen ger mindre y.
        #expect(up.pixel.y < 240)
    }

    @Test("Punkter bakom kameran projiceras inte")
    func pointsBehindTheCameraAreRejected() {
        let keyframe = Self.camera(at: .zero)
        #expect(keyframe.project(SIMD3(0, 0, 2)) == nil)
    }

    @Test("Punkter utanför bildkanten projiceras inte")
    func pointsOutsideTheFrameAreRejected() {
        let keyframe = Self.camera(at: .zero)
        // 5 m åt sidan på 2 m avstånd hamnar långt utanför en 640 px bred bild.
        #expect(keyframe.project(SIMD3(5, 0, -2)) == nil)
    }

    @Test("En förflyttad kamera projicerar relativt sin egen plats")
    func projectionFollowsTheCamera() throws {
        let keyframe = Self.camera(at: SIMD3(1, 0, 0))
        let projection = try #require(keyframe.project(SIMD3(1, 0, -2)))

        #expect(abs(projection.pixel.x - 320) < 0.001)
        #expect(abs(projection.depth - 2) < 0.001)
    }

    @Test("Texturkoordinaten ligger i enhetskvadraten")
    func textureCoordinateIsNormalised() throws {
        let keyframe = Self.camera(at: .zero)
        let projection = try #require(keyframe.project(SIMD3(0.3, 0.2, -2)))
        let uv = projection.textureCoordinate(imageSize: Self.imageSize)

        #expect(uv.x > 0 && uv.x < 1)
        #expect(uv.y > 0 && uv.y < 1)
    }

    // MARK: - Vy-val

    @Test("Den närmaste kameran målar ytan")
    func closestCameraWins() throws {
        let near = Self.camera(at: .zero, id: 1)
        let far = Self.camera(at: SIMD3(0, 0, 4), id: 2)

        let chosen = try #require(ViewSelection.best(for: Self.facingTriangle,
                                                     among: [far, near],
                                                     depth: Self.noDepth))
        #expect(chosen.id == 1)
    }

    @Test("En yta som ses från kanten väljs bort")
    func edgeOnSurfaceIsRejected() {
        // Triangeln ligger i planet x = 0 och ses exakt från kanten.
        let edgeOn = ViewSelection.Triangle(SIMD3(0, -0.2, -1.8),
                                            SIMD3(0, 0.2, -1.8),
                                            SIMD3(0, 0, -2.2))
        let keyframe = Self.camera(at: .zero)

        #expect(ViewSelection.best(for: edgeOn, among: [keyframe], depth: Self.noDepth) == nil)
    }

    @Test("En triangel som inte får plats i bilden väljs bort")
    func partiallyVisibleTriangleIsRejected() {
        // Ett hörn ligger långt utanför bildens kant.
        let clipped = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                             SIMD3(0.2, 0, -2),
                                             SIMD3(9, 0.2, -2))
        let keyframe = Self.camera(at: .zero)

        #expect(ViewSelection.best(for: clipped, among: [keyframe], depth: Self.noDepth) == nil)
    }

    @Test("En skymd yta målas inte med det som står framför")
    func occludedSurfaceIsRejected() {
        let keyframe = Self.camera(at: .zero, depthSize: SIMD2(4, 4))
        // LiDAR såg något på 1 m, men triangeln ligger 2 m bort.
        let depth: ViewSelection.DepthLookup = { _, _ in 1.0 }

        #expect(ViewSelection.best(for: Self.facingTriangle,
                                   among: [keyframe],
                                   depth: depth) == nil)
    }

    @Test("En yta som ligger där LiDAR mätte den målas")
    func visibleSurfaceSurvivesTheDepthTest() throws {
        let keyframe = Self.camera(at: .zero, id: 7, depthSize: SIMD2(4, 4))
        let depth: ViewSelection.DepthLookup = { _, _ in 2.0 }

        let chosen = try #require(ViewSelection.best(for: Self.facingTriangle,
                                                     among: [keyframe],
                                                     depth: depth))
        #expect(chosen.id == 7)
    }

    @Test("Brus i djupkartan får inte kasta bort ytan")
    func depthNoiseWithinToleranceIsAccepted() throws {
        let keyframe = Self.camera(at: .zero, id: 3, depthSize: SIMD2(4, 4))
        // 5 cm närmare än triangeln – innanför marginalen på 12 cm.
        let depth: ViewSelection.DepthLookup = { _, _ in 1.95 }

        let chosen = try #require(ViewSelection.best(for: Self.facingTriangle,
                                                     among: [keyframe],
                                                     depth: depth))
        #expect(chosen.id == 3)
    }

    @Test("Utan kameror finns ingen bild att måla med")
    func noKeyframesMeansNoChoice() {
        #expect(ViewSelection.best(for: Self.facingTriangle, among: [], depth: Self.noDepth) == nil)
    }

    @Test("En degenererad triangel saknar riktning och väljs bort")
    func degenerateTriangleIsRejected() {
        let degenerate = ViewSelection.Triangle(SIMD3(0, 0, -2), SIMD3(0, 0, -2), SIMD3(0, 0, -2))
        #expect(degenerate.normal == nil)
        #expect(ViewSelection.best(for: degenerate,
                                   among: [Self.camera(at: .zero)],
                                   depth: Self.noDepth) == nil)
    }

    @Test("Normalens tecken spelar ingen roll, bara att ytan ses rakt på")
    func flippedNormalStillCounts() throws {
        // Samma triangel med omvänd vindningsordning: normalen pekar bort.
        let flipped = ViewSelection.Triangle(Self.facingTriangle.a,
                                             Self.facingTriangle.c,
                                             Self.facingTriangle.b)
        let keyframe = Self.camera(at: .zero, id: 5)

        let chosen = try #require(ViewSelection.best(for: flipped,
                                                     among: [keyframe],
                                                     depth: Self.noDepth))
        #expect(chosen.id == 5)
    }

    // MARK: - Sammanhängande val

    /// En remsa av trianglar i planet z = −2 med delade hörn, så att
    /// grannskapet går att hitta.
    static func strip(columns: Int) -> [ViewSelection.Triangle] {
        var result: [ViewSelection.Triangle] = []
        for column in 0..<columns {
            let left = Float(column) * 0.1 - Float(columns) * 0.05
            let right = left + 0.1
            result.append(ViewSelection.Triangle(SIMD3(left, -0.05, -2),
                                                 SIMD3(right, -0.05, -2),
                                                 SIMD3(left, 0.05, -2)))
            result.append(ViewSelection.Triangle(SIMD3(right, -0.05, -2),
                                                 SIMD3(right, 0.05, -2),
                                                 SIMD3(left, 0.05, -2)))
        }
        return result
    }

    @Test("Varannan-mönstret jämnas ut till en sammanhängande yta")
    func smoothingCollapsesAlternatingChoices() {
        // Remsans trianglar pekar omväxlande nedåt och uppåt, så en kamera över
        // och en under vinner varannan triangel. Var för sig är valen riktiga,
        // men randigt är precis vad väggen inte ska bli.
        let below = Self.camera(at: SIMD3(0, -0.3, 0), id: 1)
        let above = Self.camera(at: SIMD3(0, 0.3, 0), id: 2)
        let triangles = Self.strip(columns: 6)

        let raw = ViewSelection.assign(triangles: triangles, keyframes: [below, above],
                                       depth: Self.noDepth, passes: 0)
        #expect(Set(raw.compactMap { $0 }).count == 2)

        let smoothed = ViewSelection.assign(triangles: triangles, keyframes: [below, above],
                                            depth: Self.noDepth)
        #expect(Set(smoothed.compactMap { $0 }).count == 1)
    }

    @Test("Utjämningen hittar inte på en bild där ingen dög")
    func smoothingKeepsUnseenTrianglesUnpainted() {
        // Remsan ligger bakom kameran.
        let behind = Self.camera(at: SIMD3(0, 0, -4), id: 1)
        let labels = ViewSelection.assign(triangles: Self.strip(columns: 4),
                                          keyframes: [behind],
                                          depth: Self.noDepth)

        #expect(labels.allSatisfy { $0 == nil })
    }

    @Test("Utan utjämningspass står varje triangels eget val kvar")
    func zeroPassesLeavesTheRawChoice() {
        let triangles = Self.strip(columns: 4)
        let keyframes = [Self.camera(at: SIMD3(-0.4, 0, 0), id: 1),
                         Self.camera(at: SIMD3(0.4, 0, 0), id: 2)]

        let raw = ViewSelection.assign(triangles: triangles, keyframes: keyframes,
                                       depth: Self.noDepth, passes: 0)
        let expected = triangles.map {
            ViewSelection.best(for: $0, among: keyframes, depth: Self.noDepth)?.id
        }
        #expect(raw == expected)
    }

    @Test("En yta längre bort än räckvidden målas inte")
    func distantSurfaceIsRejected() {
        let far = ViewSelection.Triangle(SIMD3(-0.2, -0.2, -8),
                                         SIMD3(0.2, -0.2, -8),
                                         SIMD3(0, 0.2, -8))
        #expect(ViewSelection.best(for: far,
                                   among: [Self.camera(at: .zero)],
                                   depth: Self.noDepth) == nil)
    }

    // MARK: - Uppdelning

    static func area(of triangle: ViewSelection.Triangle) -> Float {
        simd_length(simd_cross(triangle.b - triangle.a, triangle.c - triangle.a)) / 2
    }

    @Test("En stor triangel delas tills bitarna ryms i en bild")
    func largeTrianglesAreSplit() {
        let wall = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                          SIMD3(2.4, 0, -2),
                                          SIMD3(0, 2.4, -2))
        let pieces = ViewSelection.subdivided([wall], maximumEdge: 0.3)

        #expect(pieces.count > 1)
        for piece in pieces {
            let longest = max(simd_distance(piece.a, piece.b),
                              simd_distance(piece.b, piece.c),
                              simd_distance(piece.c, piece.a))
            #expect(longest <= 0.3)
        }
    }

    @Test("Små trianglar lämnas i fred")
    func smallTrianglesAreLeftAlone() {
        // Längsta kanten är 0,1 m — redan under gränsen.
        let small = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                           SIMD3(0.1, 0, -2),
                                           SIMD3(0, 0.1, -2))
        #expect(ViewSelection.subdivided([small], maximumEdge: 0.3) == [small])
    }

    @Test("Uppdelningen bevarar ytan, inte bara hörnen")
    func subdivisionKeepsTheArea() {
        let wall = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                          SIMD3(1.2, 0, -2),
                                          SIMD3(0, 1.2, -2))
        let pieces = ViewSelection.subdivided([wall], maximumEdge: 0.3)

        #expect(abs(pieces.reduce(0) { $0 + Self.area(of: $1) } - Self.area(of: wall)) < 0.001)
    }

    /// Djupet begränsar hur långt uppdelningen får gå — en enda triangel får
    /// inte kunna spränga minnet.
    @Test("Uppdelningen bottnar i stället för att växa fritt")
    func subdivisionRespectsItsDepthLimit() {
        let huge = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                          SIMD3(40, 0, -2),
                                          SIMD3(0, 40, -2))
        #expect(ViewSelection.subdivided([huge], maximumEdge: 0.3, maximumDepth: 2).count == 16)
    }

    @Test("Budgeten hindrar en vägg från att bli hundratusen bitar")
    func subdivisionStopsAtItsBudget() {
        let wall = ViewSelection.Triangle(SIMD3(0, 0, -2),
                                          SIMD3(4, 0, -2),
                                          SIMD3(0, 4, -2))
        let pieces = ViewSelection.subdivided([wall, wall, wall],
                                              maximumEdge: 0.05,
                                              budget: 100)
        #expect(pieces.count < 300)
    }

    // MARK: - Djupuppslag

    @Test("Bildens hörn slår upp djupkartans hörn")
    func depthIndexMapsCorners() {
        let keyframe = Self.camera(at: .zero, depthSize: SIMD2(256, 192))

        #expect(keyframe.depthIndex(for: SIMD2(0, 0)) == 0)
        let last = keyframe.depthIndex(for: SIMD2(639, 479))
        #expect(last == 192 * 256 - 1)
    }
}
