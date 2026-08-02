//
//  TexturedMeshEntity.swift
//  SpatialFit
//
//  Den bakade mesh:en och dess atlas, ihopsatta till något RealityKit ritar.
//
//  Materialet är `UnlitMaterial` av samma skäl som i `RoomTexturizer`: ljuset
//  ligger redan i fotona atlasen bakades ur. Med PBR och scenens lampor blir
//  rummet dubbelbelyst.
//

import Foundation
import RealityKit
import simd

@MainActor
enum TexturedMeshEntity {

    enum Failure: LocalizedError {
        case unreadable
        case empty

        var errorDescription: String? {
            switch self {
            case .unreadable: "Det bakade rummet gick inte att läsa."
            case .empty: "Det bakade rummet innehöll ingen yta."
            }
        }
    }

    /// Läser `baked.mesh` och `baked.png` ur rummets mapp.
    static func make(in directory: URL) throws -> Entity {
        let meshURL = directory.appending(path: TexturedMesh.meshFilename)
        guard let data = try? Data(contentsOf: meshURL),
              let mesh = TexturedMesh(data: data) else { throw Failure.unreadable }
        guard !mesh.isEmpty else { throw Failure.empty }

        var descriptor = MeshDescriptor(name: "BakedRoom")
        descriptor.positions = MeshBuffer(mesh.positions)
        descriptor.normals = MeshBuffer(mesh.normals)
        descriptor.textureCoordinates = MeshBuffer(mesh.textureCoordinates)
        descriptor.primitives = .triangles(mesh.indices)

        guard let resource = try? MeshResource.generate(from: [descriptor]) else {
            throw Failure.unreadable
        }

        let entity = ModelEntity(mesh: resource, materials: [material(in: directory)])
        entity.name = "BakedRoom"
        return entity
    }

    private static func material(in directory: URL) -> RealityKit.Material {
        var material = UnlitMaterial()
        // Väggarna är enkelsidiga. Utan detta ser man rakt ut ur rummet så fort
        // kameran hamnar innanför dem.
        material.faceCulling = .none

        let textureURL = directory.appending(path: TexturedMesh.textureFilename)
        if let texture = try? TextureResource.load(contentsOf: textureURL) {
            material.color = .init(texture: .init(texture))
        }
        return material
    }
}
