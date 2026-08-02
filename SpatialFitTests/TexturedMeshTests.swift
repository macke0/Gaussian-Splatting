//
//  TexturedMeshTests.swift
//  SpatialFitTests
//
//  Formatet delas med Python-servern. Går det isär blir rummet antingen tomt
//  eller en krasch i RealityKit, så gränserna testas var för sig.
//

import Testing
import Foundation
import simd
@testable import SpatialFit

@Suite("Bakad mesh")
struct TexturedMeshTests {

    private var quad: TexturedMesh {
        TexturedMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0),
                                 SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                     normals: [SIMD3(0, 0, 1), SIMD3(0, 0, 1),
                               SIMD3(0, 0, 1), SIMD3(0, 0, 1)],
                     textureCoordinates: [SIMD2(0, 0), SIMD2(1, 0),
                                          SIMD2(1, 1), SIMD2(0, 1)],
                     indices: [0, 1, 2, 0, 2, 3])
    }

    @Test("Positioner, normaler, UV och index tar sig hela vägen tillbaka")
    func roundTrip() throws {
        let decoded = try #require(TexturedMesh(data: quad.encoded()))
        #expect(decoded == quad)
        #expect(decoded.triangleCount == 2)
    }

    @Test("Varje hörn tar 32 byte, inte de 48 en utfylld SIMD skulle ta")
    func packedVertices() {
        #expect(quad.encoded().count == 16 + 4 * 32 + 6 * 4)
    }

    @Test("En avhuggen fil avvisas i stället för att ge halva rummet")
    func truncated() {
        let data = quad.encoded()
        #expect(TexturedMesh(data: data.prefix(data.count - 12)) == nil)
    }

    @Test("En scenmesh är inte en bakad mesh, trots att båda är binära")
    func wrongMagic() {
        let scene = SceneMesh(positions: quad.positions, indices: quad.indices)
        #expect(TexturedMesh(data: scene.encoded()) == nil)
    }

    @Test("Index utanför hörnlistan avvisas — de kraschar ritningen")
    func indexOutOfRange() {
        var broken = quad
        broken.indices = [0, 1, 7]
        #expect(TexturedMesh(data: broken.encoded()) == nil)
    }

    @Test("Ett antal index som inte går jämnt upp i trianglar avvisas")
    func danglingIndex() {
        var broken = quad
        broken.indices = [0, 1, 2, 3]
        #expect(TexturedMesh(data: broken.encoded()) == nil)
    }
}
