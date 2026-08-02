//
//  SceneMeshTests.swift
//  SpatialFitTests
//
//  Formatet på disk är handskrivet och binärt. Går det sönder tyst blir rummet
//  antingen tomt eller en krasch i RealityKit, så det testas noga.
//

import Testing
import Foundation
import simd
@testable import SpatialFit

@Suite("Scenmesh")
struct SceneMeshTests {

    private var quad: SceneMesh {
        SceneMesh(positions: [SIMD3(0, 0, 0), SIMD3(1, 0, 0),
                              SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
                  indices: [0, 1, 2, 0, 2, 3])
    }

    @Test("Ett rum tar sig oförändrat till disk och tillbaka")
    func roundTrip() throws {
        let decoded = try #require(SceneMesh(data: quad.encoded()))
        #expect(decoded == quad)
        #expect(decoded.triangleCount == 2)
    }

    @Test("Hörnen skrivs packade, inte utfyllda")
    func packedVertices() {
        // 8 byte magi + två räknare + 4 hörn à 12 byte + 6 index à 4 byte.
        #expect(quad.encoded().count == 16 + 48 + 24)
    }

    @Test("En tom mesh går att koda utan att bli något att rita")
    func empty() throws {
        let decoded = try #require(SceneMesh(data: SceneMesh().encoded()))
        #expect(decoded.isEmpty)
    }

    @Test("En avhuggen fil avvisas i stället för att ge halva rummet")
    func truncated() {
        let data = quad.encoded()
        #expect(SceneMesh(data: data.prefix(data.count - 8)) == nil)
    }

    @Test("En fil som inte är en scenmesh avvisas")
    func foreignData() {
        #expect(SceneMesh(data: Data("{\"rum\": 1}".utf8)) == nil)
    }

    @Test("Index utanför hörnlistan avvisas — de kraschar ritningen")
    func indexOutOfRange() {
        let broken = SceneMesh(positions: quad.positions, indices: [0, 1, 9])
        #expect(SceneMesh(data: broken.encoded()) == nil)
    }

    @Test("Ett antal index som inte går jämnt upp i trianglar avvisas")
    func danglingIndex() {
        let broken = SceneMesh(positions: quad.positions, indices: [0, 1, 2, 3])
        #expect(SceneMesh(data: broken.encoded()) == nil)
    }
}
