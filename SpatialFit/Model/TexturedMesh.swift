//
//  TexturedMesh.swift
//  SpatialFit
//
//  Rummet efter bakning: samma yta som `SceneMesh`, men med normaler, UV och en
//  enda textur som täcker allt.
//
//  Skillnaden mot `RoomTexturizer` är var färgen bestäms. Där väljer varje
//  triangel ett foto, och skarven mellan två foton syns som ett hopp i
//  exponering. Här har varje texel i stället vägts ihop ur alla bilder som såg
//  den, vilket är hela poängen med en atlas — men det kräver att ytan veckas ut
//  i planet, och det är för tungt för telefonen. Bakningen sker på server.
//
//  Formatet speglas i `server/spatialfit_server/mesh.py`. Ändras det ena måste
//  det andra följa med.
//

import Foundation
import simd

struct TexturedMesh: Sendable, Equatable {

    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    /// Texturkoordinat per hörn, in i atlasen.
    var textureCoordinates: [SIMD2<Float>]
    var indices: [UInt32]

    init(positions: [SIMD3<Float>] = [],
         normals: [SIMD3<Float>] = [],
         textureCoordinates: [SIMD2<Float>] = [],
         indices: [UInt32] = []) {
        self.positions = positions
        self.normals = normals
        self.textureCoordinates = textureCoordinates
        self.indices = indices
    }

    var isEmpty: Bool { indices.count < 3 }
    var triangleCount: Int { indices.count / 3 }

    /// Atlasen ligger bredvid mesh:en, inte i den. En PNG är redan komprimerad;
    /// att bädda in den skulle bara göra formatet svårare att inspektera.
    static let meshFilename = "baked.mesh"
    static let textureFilename = "baked.png"

    // MARK: - På disk

    private static let magic: [UInt8] = Array("SFTEX001".utf8)
    private static let headerSize = 8 + 4 + 4
    /// Position, normal och UV per hörn.
    private static let bytesPerVertex = 12 + 12 + 8

    func encoded() -> Data {
        var data = Data(capacity: Self.headerSize
                        + positions.count * Self.bytesPerVertex
                        + indices.count * 4)
        data.append(contentsOf: Self.magic)
        withUnsafeBytes(of: UInt32(positions.count).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(indices.count).littleEndian) { data.append(contentsOf: $0) }

        for position in positions { append(position, to: &data) }
        for normal in normals { append(normal, to: &data) }
        for coordinate in textureCoordinates {
            append(coordinate.x, to: &data)
            append(coordinate.y, to: &data)
        }
        for index in indices {
            withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private func append(_ vector: SIMD3<Float>, to data: inout Data) {
        append(vector.x, to: &data)
        append(vector.y, to: &data)
        append(vector.z, to: &data)
    }

    private func append(_ value: Float, to data: inout Data) {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
    }

    /// `nil` när filen inte är en bakad mesh, är avhuggen eller pekar utanför
    /// sig själv.
    init?(data: Data) {
        guard data.count >= Self.headerSize,
              Array(data.prefix(Self.magic.count)) == Self.magic else { return nil }

        let counts = data.withUnsafeBytes { raw -> (Int, Int) in
            (Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))),
             Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 12, as: UInt32.self))))
        }
        let (vertexCount, indexCount) = counts
        guard indexCount % 3 == 0,
              data.count == Self.headerSize
                  + vertexCount * Self.bytesPerVertex
                  + indexCount * 4 else { return nil }

        var positions = [SIMD3<Float>]()
        var normals = [SIMD3<Float>]()
        var coordinates = [SIMD2<Float>]()
        var indices = [UInt32]()
        positions.reserveCapacity(vertexCount)
        normals.reserveCapacity(vertexCount)
        coordinates.reserveCapacity(vertexCount)
        indices.reserveCapacity(indexCount)

        data.withUnsafeBytes { raw in
            var offset = Self.headerSize
            func float() -> Float {
                defer { offset += 4 }
                return Float(bitPattern: UInt32(littleEndian:
                    raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
            for _ in 0..<vertexCount { positions.append(SIMD3(float(), float(), float())) }
            for _ in 0..<vertexCount { normals.append(SIMD3(float(), float(), float())) }
            for _ in 0..<vertexCount { coordinates.append(SIMD2(float(), float())) }
            for _ in 0..<indexCount {
                indices.append(UInt32(littleEndian:
                    raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                offset += 4
            }
        }

        // Ett index utanför hörnlistan kraschar RealityKit vid ritning.
        guard indices.allSatisfy({ $0 < UInt32(vertexCount) }) else { return nil }

        self.init(positions: positions, normals: normals,
                  textureCoordinates: coordinates, indices: indices)
    }
}
