//
//  CollisionEngine.swift
//  SpatialFit
//
//  Hjärtat i produkten. Rent värdebaserat, inga sidoeffekter, inga
//  UI- eller RealityKit-beroenden – kör lika gärna på en server som i vyn.
//

import Foundation
import simd

enum CollisionEngine {

    // MARK: - Passformsverifiering

    /// Prövar produktens PIM-box mot nischens fria mått, axel för axel.
    static func evaluate(product: Product,
                         niche: Niche,
                         obstacles: [Obstacle] = [],
                         policy: FitPolicy = .standard) -> FitResult {

        let envelope = product.requiredEnvelope
        let threshold = policy.greenClearanceMM + (policy.addsScanTolerance ? niche.toleranceMM : 0)

        let axes = policy.evaluatedAxes.map { axis in
            AxisClearance(axis: axis,
                          availableMM: niche.dimensions[axis],
                          requiredMM: envelope[axis],
                          greenThresholdMM: threshold)
        }

        let placement = placement(for: product, in: niche)
        let hits = intersections(productBox: placement, obstacles: obstacles)

        return FitResult(product: product,
                         niche: niche,
                         axes: axes,
                         intersections: hits)
    }

    // MARK: - Placering

    /// Var produkten hamnar när den ställs i nischen: centrerad i sidled,
    /// stående på golvet, inskjuten mot bakkant. Det är så en spis faktiskt
    /// installeras, och det är den placering överhänget ska beräknas ur.
    static func placement(for product: Product, in niche: Niche) -> BoxAABB {
        let size = product.requiredEnvelope.metersSize
        return BoxAABB(
            center: SIMD3(niche.center.x,
                          niche.floorLevel + size.y / 2,
                          niche.backPlane + size.z / 2),
            size: size
        )
    }

    // MARK: - Krockdetektering

    /// Faktiska överlappsvolymer mellan produkten och rummets hinder.
    /// Det är dessa lådor som renderas med pulserande röd shader – vi gissar
    /// alltså aldrig var krocken sitter, vi räknar ut den.
    static func intersections(productBox: BoxAABB, obstacles: [Obstacle]) -> [Intersection] {
        obstacles.compactMap { obstacle in
            guard obstacle.isCollidable,
                  let overlap = productBox.intersection(with: obstacle.box) else { return nil }
            return Intersection(id: obstacle.id, obstacle: obstacle, box: overlap)
        }
        .sorted { $0.penetrationMM > $1.penetrationMM }
    }
}
