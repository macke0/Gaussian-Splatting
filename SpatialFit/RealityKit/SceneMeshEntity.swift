//
//  SceneMeshEntity.swift
//  SpatialFit
//
//  Gör den täta LiDAR-ytan till något RealityKit kan rita.
//
//  ARKit ger bara hörn och trianglar. Normalerna räknas fram här, som en
//  ytviktad medelnormal per hörn: utan dem blir mesh:en svart, och med bara
//  triangelnormaler blir en rundad form fasetterad.
//

import Foundation
import RealityKit
import simd

@MainActor
enum SceneMeshEntity {

    /// `nil` när mesh:en är tom eller RealityKit inte tar den.
    static func make(from mesh: SceneMesh) -> Entity? {
        guard !mesh.isEmpty else { return nil }

        var descriptor = MeshDescriptor(name: "SceneMesh")
        descriptor.positions = MeshBuffer(mesh.positions)
        descriptor.normals = MeshBuffer(normals(of: mesh))
        descriptor.primitives = .triangles(mesh.indices)

        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: resource, materials: [surfaceMaterial])
        entity.name = "SceneMesh"
        return entity
    }

    private static func normals(of mesh: SceneMesh) -> [SIMD3<Float>] {
        var normals = [SIMD3<Float>](repeating: .zero, count: mesh.positions.count)
        for triangle in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let a = Int(mesh.indices[triangle])
            let b = Int(mesh.indices[triangle + 1])
            let c = Int(mesh.indices[triangle + 2])
            // Kryssprodukten är dubbla triangelarean, så stora trianglar väger
            // tyngre av sig själva.
            let face = simd_cross(mesh.positions[b] - mesh.positions[a],
                                  mesh.positions[c] - mesh.positions[a])
            normals[a] += face
            normals[b] += face
            normals[c] += face
        }
        return normals.map { normal in
            let length = simd_length(normal)
            return length > 0 ? normal / length : SIMD3(0, 1, 0)
        }
    }

    /// Samma grå som RoomPlan-mesh:en får, med tvåsidig rendering — LiDAR-ytan
    /// är lika enkelsidig som väggarna.
    private static var surfaceMaterial: PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(white: 0.78, alpha: 1))
        material.roughness = 0.9
        material.metallic = 0.0
        material.faceCulling = .none
        return material
    }
}
