//
//  CoverageMeshEntity.swift
//  SpatialFit
//
//  Rummets yta målad efter hur väl skanningen täckte den.
//
//  Samma geometri som `SceneMeshEntity`, men trianglarna delas på tre material:
//  grönt där ytan är uppmätt från flera håll, gult där den bara skymtats från
//  ett, rött där inget foto ser den alls. Det röda är det som räknas — det är
//  där rummet faller isär när man vrider sig i det, och det enda som lagar det
//  är att gå tillbaka och fotografera.
//
//  `MeshDescriptor.Materials.perFace` gör det i ett enda draw call. Alternativet
//  vore tre separata meshar, som skulle behöva var sin hörnlista.
//

import Foundation
import RealityKit
import simd

@MainActor
enum CoverageMeshEntity {

    /// `nil` när mesh:en är tom eller RealityKit inte tar den.
    static func make(from mesh: SceneMesh, report: SurfaceCoverage.Report) -> Entity? {
        guard !mesh.isEmpty, report.faceLevels.count == mesh.triangleCount else { return nil }

        var descriptor = MeshDescriptor(name: "CoverageMesh")
        descriptor.positions = MeshBuffer(mesh.positions)
        descriptor.normals = MeshBuffer(mesh.vertexNormals())
        descriptor.primitives = .triangles(mesh.indices)
        descriptor.materials = .perFace(report.faceLevels)

        guard let resource = try? MeshResource.generate(from: [descriptor]) else { return nil }
        let entity = ModelEntity(mesh: resource,
                                 materials: SurfaceCoverage.Level.allCases.map(material))
        entity.name = "CoverageMesh"
        return entity
    }

    /// Matt och tvåsidig, som den grå ytan. Att låta scenens ljus spela på
    /// färgen är med flit: helt platta fält gör att formen försvinner, och då
    /// går det inte att se VAR i rummet det röda sitter.
    private static func material(for level: SurfaceCoverage.Level) -> PhysicallyBasedMaterial {
        let tint = level.tint
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(red: tint.red, green: tint.green,
                                               blue: tint.blue, alpha: 1))
        material.roughness = 0.9
        material.metallic = 0.0
        material.faceCulling = .none
        return material
    }
}
