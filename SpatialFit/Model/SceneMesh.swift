//
//  SceneMesh.swift
//  SpatialFit
//
//  Den täta ytan LiDAR faktiskt mätte upp — trianglar i världskoordinater.
//
//  RoomPlan svarar på frågan "vad är det här för rum": väggar som plan, möbler
//  som lådor med en kategori. Det är rätt underlag för att mäta en nisch, men
//  en diskbänk är inte en låda. Ska rummet gå att känna igen visuellt behövs
//  den ytan ARKit rekonstruerar bakom RoomPlans tolkning.
//
//  Formatet är avsiktligt rått. Ett par hundra tusen hörn som JSON blir tiotals
//  megabyte text att koda och avkoda; som binärt är det en rak minneskopia.
//

import Foundation
import simd

struct SceneMesh: Sendable, Equatable {

    var positions: [SIMD3<Float>]
    /// Tre index per triangel, in i `positions`.
    var indices: [UInt32]

    init(positions: [SIMD3<Float>] = [], indices: [UInt32] = []) {
        self.positions = positions
        self.indices = indices
    }

    var isEmpty: Bool { indices.count < 3 }
    var triangleCount: Int { indices.count / 3 }

    // MARK: - På disk

    private static let magic: [UInt8] = Array("SFMESH01".utf8)
    private static let headerSize = 8 + 4 + 4

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize
                        + positions.count * 12
                        + indices.count * 4)
        data.append(contentsOf: Self.magic)
        withUnsafeBytes(of: UInt32(positions.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(indices.count).littleEndian) { data.append(contentsOf: $0) }

        // Hörnen skrivs som tre flyttal. `SIMD3<Float>` är utfyllt till 16 byte
        // i minnet, vilket skulle slösa en fjärdedel av filen.
        for position in positions {
            withUnsafeBytes(of: position.x.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: position.y.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: position.z.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// `nil` när filen inte är en scenmesh eller är avhuggen.
    init?(data: Data) {
        guard data.count >= Self.headerSize,
              Array(data.prefix(Self.magic.count)) == Self.magic else { return nil }

        let counts = data.withUnsafeBytes { raw -> (Int, Int) in
            (Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
             Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))))
        }
        let (vertexCount, indexCount) = counts
        guard indexCount % 3 == 0,
              data.count == Self.headerSize + vertexCount * 12 + indexCount * 4 else { return nil }

        var positions = [SIMD3<Float>]()
        var indices = [UInt32]()
        positions.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)

        data.withUnsafeBytes { raw in
            var offset = Self.headerSize
            for _ in 0..<vertexCount {
                let x = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                let y = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                let z = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 8, as: UInt32.self)))
                positions.append(SIMD3(x, y, z))
                offset += 12
            }
            for _ in 0..<indexCount {
                indices.append(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
            }
        }

        // Ett index utanför hörnlistan kraschar RealityKit vid ritning.
        guard indices.allSatisfy({ $0 < UInt32(vertexCount) }) else { return nil }

        self.init(positions: positions, indices: indices)
    }
}
