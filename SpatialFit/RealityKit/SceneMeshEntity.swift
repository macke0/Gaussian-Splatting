//
//  SceneMeshEntity.swift
//  SpatialFit
//
//  Gör den täta LiDAR-ytan till något RealityKit kan rita.
//
//  Normalerna kommer från `SceneMesh.vertexNormals()` — ARKit ger bara hörn och
//  trianglar, och utan normaler blir ytan svart.
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
        descriptor.normals = MeshBuffer(mesh.vertexNormals())
        descriptor.primitives = .triangles(mesh.indices)

        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: resource, materials: [surfaceMaterial])
        entity.name = "SceneMesh"
        return entity
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
