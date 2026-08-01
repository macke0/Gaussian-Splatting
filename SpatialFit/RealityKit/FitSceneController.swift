//
//  FitSceneController.swift
//  SpatialFit
//
//  Översätter ett FitResult till entiteter. Den enda filen som känner till
//  BÅDE affärslogiken och RealityKit – allt annat är rent åt ena eller andra
//  hållet.
//
//  Scenens rot är en tom Entity. När RoomPlan kopplas in i steg 2 hängs den
//  under en ARAnchorEntity i stället för under kamerariggen; inget nedan
//  behöver ändras.
//

import Foundation
import RealityKit
import UIKit
import simd

/// Avsiktligt INTE `@MainActor`: klassen instansieras som default-värde till en
/// `@State`-property, vilket sker i ett nonisolated sammanhang. All faktisk
/// användning sker ändå från RealityViews closures, som körs på main.
final class FitSceneController {

    /// Allt som hör till rummet + produkten.
    let root = Entity()
    /// Kamerarigg för den virtuella (icke-AR) förhandsvisningen.
    let cameraRig = Entity()

    private let staticRoot = Entity()     // rum: golv, väggar, skåp
    private let nicheRoot = Entity()      // nischmarkering + mått
    private let productRoot = Entity()    // produkt, ram, krockvolymer

    private var builtSceneID: String?
    private var renderedStateID: String?

    // MARK: - Palett

    private enum Palette {
        static let floor      = UIColor(white: 0.62, alpha: 1)
        static let wall       = UIColor(white: 0.86, alpha: 1)
        static let cabinet    = UIColor(red: 0.93, green: 0.91, blue: 0.87, alpha: 1)
        static let counter    = UIColor(red: 0.22, green: 0.23, blue: 0.25, alpha: 1)
        static let product    = UIColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1)
        static let nicheGuide = UIColor(red: 0.35, green: 0.70, blue: 1.00, alpha: 1)
        static let green      = UIColor(red: 0.18, green: 0.82, blue: 0.44, alpha: 1)
        static let yellow     = UIColor(red: 1.00, green: 0.78, blue: 0.13, alpha: 1)
        static let red        = UIColor(red: 1.00, green: 0.23, blue: 0.23, alpha: 1)

        static func color(for zone: FitZone) -> UIColor {
            switch zone {
            case .green:  return green
            case .yellow: return yellow
            case .red:    return red
            }
        }
    }

    init() {
        root.addChild(staticRoot)
        root.addChild(nicheRoot)
        root.addChild(productRoot)
        cameraRig.addChild(makeCamera())
        addLighting()
    }

    // MARK: - Rummet (byggs en gång per nisch)

    func buildRoom(niche: Niche, obstacles: [Obstacle]) {
        guard builtSceneID != niche.id else { return }
        builtSceneID = niche.id

        staticRoot.children.removeAll()
        nicheRoot.children.removeAll()

        for obstacle in obstacles {
            let color: UIColor
            switch obstacle.kind {
            case .floor:      color = Palette.floor
            case .wall:       color = Palette.wall
            case .cabinet:    color = Palette.cabinet
            case .counterTop: color = Palette.counter
            case .appliance:  color = Palette.product
            }
            let entity = EntityFactory.box(obstacle.box, color: color,
                                           roughness: obstacle.kind == .counterTop ? 0.35 : 0.85)
            entity.name = obstacle.id
            staticRoot.addChild(entity)
        }

        // Nischens fria volym markeras alltid – det är den kunden köper mot.
        nicheRoot.addChild(
            EntityFactory.wireBox(niche.box, color: Palette.nicheGuide,
                                  thickness: 0.004, opacity: 0.85)
        )

        let labelY = niche.center.y + niche.dimensions.height.asMeters / 2 + 0.12
        let labelZ = niche.center.z + niche.dimensions.depth.asMeters / 2
        nicheRoot.addChild(
            EntityFactory.label("NISCH \(Units.format(niche.dimensions.width))",
                                color: Palette.nicheGuide,
                                size: 0.055,
                                at: SIMD3(niche.center.x, labelY, labelZ))
        )
    }

    // MARK: - Produkten (byggs om vid varje ändrat resultat)

    func render(_ fit: FitResult) {
        let stateID = "\(fit.product.id)-\(fit.zone.rawValue)-\(fit.intersections.count)"
        guard renderedStateID != stateID else { return }
        renderedStateID = stateID

        productRoot.children.removeAll()

        let placement = CollisionEngine.placement(for: fit.product, in: fit.niche)

        // 1. Produktkroppen. Neutral – färgen ska sitta på bedömningen,
        //    inte på produkten.
        let body = EntityFactory.box(placement, color: Palette.product,
                                     roughness: 0.35, metallic: 0.25)
        body.name = "product-body"
        productRoot.addChild(body)

        // 2. Statusram runt produkten.
        let zoneColor = Palette.color(for: fit.zone)
        if fit.zone == .red {
            productRoot.addChild(
                EntityFactory.pulsingWireBox(inflated(placement, by: 0.004),
                                             pulse: .collisionEdge)
            )
        } else {
            productRoot.addChild(
                EntityFactory.wireBox(inflated(placement, by: 0.004),
                                      color: zoneColor,
                                      thickness: fit.zone == .green ? 0.005 : 0.007,
                                      opacity: fit.zone == .green ? 0.85 : 1.0)
            )
        }

        // 3. Krockvolymerna – de faktiska skärningarna mot skåp och väggar,
        //    pulserande röd/orange.
        for hit in fit.intersections {
            let volume = EntityFactory.translucentBox(inflated(hit.box, by: 0.002),
                                                      color: Palette.red,
                                                      opacity: 0.45)
            volume.name = "collision-\(hit.id)"
            volume.components.set(PulseComponent.collision)
            productRoot.addChild(volume)

            productRoot.addChild(
                EntityFactory.label("+\(Int(hit.penetrationMM.rounded())) mm",
                                    color: Palette.red,
                                    size: 0.04,
                                    at: SIMD3(hit.box.center.x,
                                              hit.box.maxCorner.y + 0.06,
                                              hit.box.maxCorner.z))
            )
        }
    }

    // MARK: - Kamera

    /// Orbit runt nischen. Bara för demot – i AR styr användaren kameran
    /// genom att gå runt i rummet.
    func setCamera(yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float>) {
        let clampedPitch = max(-0.35, min(1.1, pitch))
        let x = distance * cos(clampedPitch) * sin(yaw)
        let y = distance * sin(clampedPitch)
        let z = distance * cos(clampedPitch) * cos(yaw)
        cameraRig.position = target
        if let camera = cameraRig.children.first {
            camera.position = SIMD3(x, y, z)
            camera.look(at: .zero, from: camera.position, relativeTo: cameraRig)
        }
    }

    private func makeCamera() -> Entity {
        let camera = PerspectiveCamera()
        camera.camera.fieldOfViewInDegrees = 45
        camera.camera.near = 0.05
        camera.camera.far = 50
        return camera
    }

    private func addLighting() {
        let key = DirectionalLight()
        key.light.intensity = 2600
        key.light.color = .white
        key.shadow = DirectionalLightComponent.Shadow(maximumDistance: 6, depthBias: 1.5)
        key.look(at: .zero, from: SIMD3(1.6, 2.6, 2.2), relativeTo: nil)
        root.addChild(key)

        let fill = DirectionalLight()
        fill.light.intensity = 1200
        fill.light.color = UIColor(red: 0.85, green: 0.90, blue: 1.0, alpha: 1)
        fill.look(at: .zero, from: SIMD3(-2.2, 1.6, 1.4), relativeTo: nil)
        root.addChild(fill)

        let bounce = DirectionalLight()
        bounce.light.intensity = 700
        bounce.light.color = .white
        bounce.look(at: .zero, from: SIMD3(0, 0.4, -2.5), relativeTo: nil)
        root.addChild(bounce)
    }

    // MARK: - Hjälpare

    /// Blås upp en låda några millimeter så att ramar och krockvolymer inte
    /// z-fightar mot produktens yta.
    private func inflated(_ box: BoxAABB, by meters: Float) -> BoxAABB {
        BoxAABB(center: box.center, size: box.size + SIMD3(repeating: meters * 2))
    }
}
