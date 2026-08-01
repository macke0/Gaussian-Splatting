//
//  Niche.swift
//  SpatialFit
//
//  En nisch = det tomma utrymmet en produkt ska in i. I steg 1 är den mockad,
//  i steg 2 härleds den ur RoomPlan (`CapturedRoom`) genom att mäta gapet
//  mellan två `.storage`-objekt eller mellan ett objekt och en `.wall`.
//

import Foundation
import simd

/// Var måtten kommer ifrån. Påverkar hur mycket vi vågar lita på dem och
/// därmed hur strikt gul zon sätts.
enum MeasurementSource: String, Sendable {
    case mock
    case roomPlan
    case lidarRefined     // RoomPlan + temporal averaging / edge snap
    case manual           // kunden har måttat med tumstock

    var label: String {
        switch self {
        case .mock:         return "Demodata"
        case .roomPlan:     return "RoomPlan-skanning"
        case .lidarRefined: return "LiDAR (finmätt)"
        case .manual:       return "Manuellt mått"
        }
    }

    /// Typisk mätosäkerhet (± mm) för källan. Visas i UI så säljaren vet när
    /// hen ska be kunden kontrollmäta.
    var nominalToleranceMM: Double {
        switch self {
        case .mock:         return 0
        case .roomPlan:     return 15
        case .lidarRefined: return 3
        case .manual:       return 2
        }
    }
}

struct Niche: Identifiable, Equatable, Sendable {
    let id: String
    /// "Nisch mellan underskåp"
    let label: String
    /// Fritt mått i mm (b × h × d).
    let dimensions: Dimensions3D
    let source: MeasurementSource
    /// Nischvolymens mittpunkt i scenens koordinatsystem, meter.
    /// (Prototypen antar att nischen är axelriktad – se Geometry.swift.)
    let center: SIMD3<Float>

    var toleranceMM: Double { source.nominalToleranceMM }

    /// Nischens volym som en låda, för renderingen.
    var box: BoxAABB {
        BoxAABB(center: center, size: dimensions.metersSize)
    }

    /// Golvnivå (y) i nischen – produkten ställs på den.
    var floorLevel: Float { center.y - dimensions.height.asMeters / 2 }
    /// Bakkant (z) i nischen – produkten skjuts in mot den.
    var backPlane: Float { center.z - dimensions.depth.asMeters / 2 }
}

// MARK: - Datakälla

/// Allt som kan leverera en nisch + omgivande hinder. Vyerna och motorn känner
/// bara till detta protokoll – därför blir steg 2 ett byte av implementation,
/// inte en omskrivning.
protocol NicheSource {
    var niche: Niche { get }
    var obstacles: [Obstacle] { get }
}

/// Mockad köksnisch: 600 mm fritt mellan två 600-underskåp med bänkskiva,
/// mot en bakvägg. Motsvarar den vanligaste spis-situationen i butik.
struct MockKitchenNiche: NicheSource {

    // Alla mått i mm, konverteras till meter först vid boxbygget.
    private let nicheWidth: Double = 600
    private let nicheHeight: Double = 900
    private let nicheDepth: Double = 650
    private let cabinetWidth: Double = 600
    private let counterThickness: Double = 40

    let niche: Niche

    init() {
        let center = SIMD3<Float>(0, nicheHeight.asMeters / 2, 0)
        niche = Niche(
            id: "mock-niche-1",
            label: "Nisch mellan underskåp",
            dimensions: Dimensions3D(nicheWidth, nicheHeight, nicheDepth),
            source: .mock,
            center: center
        )
    }

    var obstacles: [Obstacle] {
        let nw = nicheWidth.asMeters
        let nh = nicheHeight.asMeters
        let nd = nicheDepth.asMeters
        let cw = cabinetWidth.asMeters
        let ct = counterThickness.asMeters

        // Skåpen flankerar nischen; deras inre kanter definierar den fria bredden.
        let cabinetCenterX = nw / 2 + cw / 2

        func cabinet(_ id: String, sign: Float) -> Obstacle {
            Obstacle(
                id: id,
                kind: .cabinet,
                box: BoxAABB(center: SIMD3(sign * cabinetCenterX, nh / 2, 0),
                             size: SIMD3(cw, nh, nd))
            )
        }

        // Bänkskivan skjuter ut 20 mm framåt (z) men aldrig in över nischen (x) –
        // annars får vi falska krockar för höga produkter.
        func counter(_ id: String, sign: Float) -> Obstacle {
            Obstacle(
                id: id,
                kind: .counterTop,
                box: BoxAABB(center: SIMD3(sign * cabinetCenterX, nh + ct / 2, 0.01),
                             size: SIMD3(cw, ct, nd + 0.02))
            )
        }

        return [
            cabinet("cabinet-left", sign: -1),
            cabinet("cabinet-right", sign: +1),
            counter("counter-left", sign: -1),
            counter("counter-right", sign: +1),
            Obstacle(id: "back-wall",
                     kind: .wall,
                     box: BoxAABB(center: SIMD3(0, 1.3, -nd / 2 - 0.05),
                                  size: SIMD3(4.0, 2.6, 0.1))),
            Obstacle(id: "floor",
                     kind: .floor,
                     box: BoxAABB(center: SIMD3(0, -0.025, 0.4),
                                  size: SIMD3(4.0, 0.05, 3.0)),
                     isCollidable: false)
        ]
    }
}
