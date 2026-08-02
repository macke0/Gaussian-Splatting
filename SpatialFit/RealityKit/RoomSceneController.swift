//
//  RoomSceneController.swift
//  SpatialFit
//
//  Scenen för att titta på ett skannat rum. Kameran sitter på en rigg som
//  kretsar kring rummets mitt: dra för att vrida, nyp för att gå in i eller ut
//  ur rummet. Minsta avstånd är litet med flit – poängen är att kunna ställa
//  sig mitt i rummet och se sig omkring.
//
//  Mesh:en från RoomPlan saknar textur. För att formen ändå ska framträda får
//  den ett eget material med tvåsidig rendering (annars försvinner väggarna när
//  man står innanför dem) och två riktade ljus, så att inga ytor blir svarta.
//

import Foundation
import RealityKit

@MainActor
final class RoomSceneController {

    let root = Entity()

    private let pivot = Entity()
    private let camera = PerspectiveCamera()
    private var model: Entity?

    /// Halva rummets största utsträckning. Styr hur långt ut kameran får gå.
    private(set) var roomRadius: Float = 3

    var defaultDistance: Float { roomRadius * 1.9 }
    var minimumDistance: Float { 0.2 }
    var maximumDistance: Float { max(roomRadius * 4, 4) }

    init() {
        camera.camera.near = 0.03
        camera.camera.far = 200
        pivot.addChild(camera)
        root.addChild(pivot)
        addLighting()
    }

    /// Byter ut rummet i scenen och centrerar riggen på det.
    ///
    /// - Parameter lit: sant för den grå mesh:en, som behöver scenens ljus för
    ///   att formen ska synas. Falskt för den fotograferade, där ljuset redan
    ///   ligger i bilden — den skulle bara bli dubbelbelyst.
    func install(_ loaded: Entity, lit: Bool = true) {
        model?.removeFromParent()
        if lit { applySurfaceMaterial(to: loaded) }
        root.addChild(loaded)
        model = loaded

        let bounds = loaded.visualBounds(relativeTo: root)
        // Rummets mitt, inte ett produktmått – `visualBounds` är rätt verktyg här.
        pivot.position = bounds.center
        roomRadius = max(bounds.extents.max() / 2, 0.5)
    }

    func setCamera(yaw: Float, pitch: Float, distance: Float) {
        let clampedPitch = min(max(pitch, -1.45), 1.45)
        pivot.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: clampedPitch, axis: [1, 0, 0])
        camera.position = [0, 0, max(distance, minimumDistance)]
    }

    // MARK: - Utseende

    private static var surfaceMaterial: PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: .init(white: 0.78, alpha: 1))
        material.roughness = 0.9
        material.metallic = 0.0
        // Väggarna är enkelsidiga ytor. Utan detta ser man rakt ut ur rummet
        // så fort kameran hamnar innanför dem.
        material.faceCulling = .none
        return material
    }

    private func applySurfaceMaterial(to entity: Entity) {
        if var component = entity.components[ModelComponent.self] {
            // En `ModelComponent` utan material kraschar RealityKit vid rendering,
            // och RoomPlans export har inte alltid ett per del.
            let replaced = component.materials.map { _ in Self.surfaceMaterial }
            component.materials = replaced.isEmpty ? [Self.surfaceMaterial] : replaced
            entity.components.set(component)
        }
        for child in entity.children {
            applySurfaceMaterial(to: child)
        }
    }

    private func addLighting() {
        root.addChild(directionalLight(intensity: 5500,
                                       rotation: .init(angle: -.pi / 3, axis: [1, 0, 0])))
        root.addChild(directionalLight(intensity: 2200,
                                       rotation: .init(angle: .pi * 0.8, axis: simd_normalize([0.4, 1, 0]))))
    }

    private func directionalLight(intensity: Float, rotation: simd_quatf) -> Entity {
        let light = DirectionalLight()
        light.light.intensity = intensity
        light.light.color = .white
        light.orientation = rotation
        return light
    }
}
