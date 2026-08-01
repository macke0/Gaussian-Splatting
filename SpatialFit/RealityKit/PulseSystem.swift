//
//  PulseSystem.swift
//  SpatialFit
//
//  Pulserande varningsmaterial, implementerat som ett RealityKit-ECS-system.
//  Att lägga det i ett System (i stället för en Timer i vyn) gör att pulsen
//  följer renderloopen och fortsätter fungera oförändrat när scenen byts från
//  virtuell kamera till world tracking.
//
//  Steg 2/3: ersätt materialbytet nedan med en CustomMaterial (Metal surface
//  shader) som klipper mot krockplanet – då kan hela produktmeshens
//  intrángande del färgas i stället för överlappslådan. Komponenten och
//  systemet kan behållas som de är; bara `apply` behöver skrivas om.
//

import Foundation
import RealityKit
import UIKit

/// Får en entitet att andas mellan två färger/opaciteter.
struct PulseComponent: Component {
    var colorA: UIColor
    var colorB: UIColor
    var opacityA: Float
    var opacityB: Float
    /// Sekunder för ett helt varv (fram och tillbaka).
    var period: Float
    /// 0...1, avancerar med deltaTime.
    var phase: Float = 0

    static let collision = PulseComponent(
        colorA: UIColor(red: 1.00, green: 0.19, blue: 0.19, alpha: 1),   // röd
        colorB: UIColor(red: 1.00, green: 0.55, blue: 0.10, alpha: 1),   // orange
        opacityA: 0.30,
        opacityB: 0.75,
        period: 1.1
    )

    static let collisionEdge = PulseComponent(
        colorA: UIColor(red: 1.00, green: 0.19, blue: 0.19, alpha: 1),
        colorB: UIColor(red: 1.00, green: 0.75, blue: 0.20, alpha: 1),
        opacityA: 0.70,
        opacityB: 1.0,
        period: 1.1
    )
}

final class PulseSystem: System {

    private static let query = EntityQuery(where: .has(PulseComponent.self))

    required init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)

        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard var pulse = entity.components[PulseComponent.self],
                  var model = entity.components[ModelComponent.self] else { continue }

            pulse.phase = (pulse.phase + dt / max(pulse.period, 0.01))
                .truncatingRemainder(dividingBy: 1)

            // Mjuk cosinuskurva i stället för sågtand – ger en "andning",
            // inte ett blink.
            let t = 0.5 - 0.5 * cos(pulse.phase * 2 * .pi)

            let color = UIColor.blend(pulse.colorA, pulse.colorB, t: CGFloat(t))
            let opacity = pulse.opacityA + (pulse.opacityB - pulse.opacityA) * t

            var material = UnlitMaterial(color: color)
            material.blending = .transparent(opacity: .init(floatLiteral: opacity))
            material.faceCulling = .none
            model.materials = [material]

            entity.components.set(model)
            entity.components.set(pulse)
        }
    }
}

extension UIColor {
    static func blend(_ a: UIColor, _ b: UIColor, t: CGFloat) -> UIColor {
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: ar + (br - ar) * t,
                       green: ag + (bg - ag) * t,
                       blue: ab + (bb - ab) * t,
                       alpha: aa + (ba - aa) * t)
    }
}
