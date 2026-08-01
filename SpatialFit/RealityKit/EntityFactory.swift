//
//  EntityFactory.swift
//  SpatialFit
//
//  Små, återanvändbara byggstenar för scenen. Inget affärslogik här –
//  bara "gör en låda", "gör en trådram", "gör en etikett".
//

import Foundation
import RealityKit
import UIKit
import simd

enum EntityFactory {

    // MARK: - Solida lådor

    static func box(_ aabb: BoxAABB,
                    color: UIColor,
                    roughness: Float = 0.8,
                    metallic: Float = 0.0,
                    cornerRadius: Float = 0.002) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: aabb.size, cornerRadius: cornerRadius)
        var material = SimpleMaterial()
        material.color = .init(tint: color)
        material.roughness = .init(floatLiteral: roughness)
        material.metallic = .init(floatLiteral: metallic)
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = aabb.center
        return entity
    }

    /// Halvtransparent volym – används för överlappslådorna innan pulsen
    /// tar över materialet.
    static func translucentBox(_ aabb: BoxAABB, color: UIColor, opacity: Float) -> ModelEntity {
        let mesh = MeshResource.generateBox(size: aabb.size)
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = aabb.center
        return entity
    }

    // MARK: - Trådram

    /// 12 tunna stavar som bildar kanterna på en låda. Läses mycket tydligare
    /// i AR än en genomskinlig volym, och skymmer inte produkten.
    static func wireBox(_ aabb: BoxAABB,
                        color: UIColor,
                        thickness: Float = 0.006,
                        opacity: Float = 1.0) -> Entity {
        let parent = Entity()
        parent.position = aabb.center

        let s = aabb.size
        let h = s / 2
        let t = thickness

        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))

        func bar(size: SIMD3<Float>, at position: SIMD3<Float>) {
            let entity = ModelEntity(mesh: .generateBox(size: size), materials: [material])
            entity.position = position
            parent.addChild(entity)
        }

        for sy in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                bar(size: SIMD3(s.x + t, t, t), at: SIMD3(0, sy * h.y, sz * h.z))
            }
        }
        for sx in [Float(-1), 1] {
            for sz in [Float(-1), 1] {
                bar(size: SIMD3(t, s.y, t), at: SIMD3(sx * h.x, 0, sz * h.z))
            }
        }
        for sx in [Float(-1), 1] {
            for sy in [Float(-1), 1] {
                bar(size: SIMD3(t, t, s.z + t), at: SIMD3(sx * h.x, sy * h.y, 0))
            }
        }
        return parent
    }

    /// Trådram där varje stav får sin egen PulseComponent – hela ramen andas.
    static func pulsingWireBox(_ aabb: BoxAABB,
                               pulse: PulseComponent,
                               thickness: Float = 0.008) -> Entity {
        let frame = wireBox(aabb, color: pulse.colorA, thickness: thickness)
        for child in frame.children {
            child.components.set(pulse)
        }
        return frame
    }

    // MARK: - Måttetikett

    static func label(_ text: String,
                      color: UIColor,
                      size: CGFloat = 0.05,
                      at position: SIMD3<Float>) -> ModelEntity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: size, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        // generateText lägger origo i textens nedre vänstra hörn – centrera.
        let bounds = entity.visualBounds(relativeTo: nil)
        entity.position = position - SIMD3(bounds.center.x, bounds.center.y, 0)
        return entity
    }
}
