//
//  Geometry.swift
//  SpatialFit
//
//  Ren geometri i METER. Inga RealityKit-beroenden – det gör att motorn kan
//  unit-testas och köras headless (t.ex. i en batch-validering av ett helt
//  kök mot en PIM-export).
//
//  OBS: Prototypen använder axelriktade lådor (AABB). Riktig RoomPlan-data är
//  roterad i världsrymden; steg 2 är att transformera in produkt + hinder i
//  nischens lokala koordinatsystem (då är AABB-matematiken nedan giltig igen)
//  eller byta till OBB/SAT. Se README.
//

import Foundation
import simd

/// Axelriktad låda i meter.
struct BoxAABB: Equatable, Sendable {
    var center: SIMD3<Float>
    var size: SIMD3<Float>

    init(center: SIMD3<Float>, size: SIMD3<Float>) {
        self.center = center
        self.size = size
    }

    var minCorner: SIMD3<Float> { center - size / 2 }
    var maxCorner: SIMD3<Float> { center + size / 2 }

    static func from(minCorner lo: SIMD3<Float>, maxCorner hi: SIMD3<Float>) -> BoxAABB {
        BoxAABB(center: (lo + hi) / 2, size: hi - lo)
    }

    /// Överlappsvolymen mot en annan låda, eller `nil` om de bara tangerar.
    ///
    /// - Parameter epsilon: Minsta överlapp (meter) som räknas som en krock.
    ///   0.5 mm default – två ytor som ligger kant i kant (produkt mot golv,
    ///   produkt mot bakvägg) ska inte larma.
    func intersection(with other: BoxAABB, epsilon: Float = 0.0005) -> BoxAABB? {
        let lo = simd_max(minCorner, other.minCorner)
        let hi = simd_min(maxCorner, other.maxCorner)
        let extent = hi - lo
        guard extent.x > epsilon, extent.y > epsilon, extent.z > epsilon else { return nil }
        return .from(minCorner: lo, maxCorner: hi)
    }

    /// Storleken uttryckt i millimeter, för UI.
    var dimensions: Dimensions3D { Dimensions3D(metersSize: size) }
}

// MARK: - Hinder

/// Vad ett hinder är för något. Styr både färgsättning i scenen och hur
/// allvarlig en krock mot det är i texten till användaren.
enum ObstacleKind: String, Sendable {
    case wall
    case cabinet
    case counterTop
    case floor
    case appliance

    var label: String {
        switch self {
        case .wall:       return "Vägg"
        case .cabinet:    return "Skåpstomme"
        case .counterTop: return "Bänkskiva"
        case .floor:      return "Golv"
        case .appliance:  return "Befintlig vitvara"
        }
    }
}

/// Ett fysiskt hinder i rummet. I steg 1 kommer dessa från `MockKitchenNiche`,
/// i steg 2 från `CapturedRoom.walls` / `CapturedRoom.objects`.
struct Obstacle: Identifiable, Equatable, Sendable {
    let id: String
    let kind: ObstacleKind
    let box: BoxAABB
    /// Hinder som produkten får skära (golvet står produkten ju på).
    var isCollidable: Bool = true
}

/// En konkret krock mellan produktens bounding box och ett hinder.
struct Intersection: Identifiable, Equatable, Sendable {
    let id: String
    let obstacle: Obstacle
    /// Själva överlappsvolymen – det är den vi renderar pulserande röd.
    let box: BoxAABB

    var overlap: Dimensions3D { box.dimensions }

    /// Den axel där produkten tränger in djupast i hindret.
    var deepestAxis: Axis {
        let s = box.size
        if s.x <= s.y && s.x <= s.z { return .width }
        if s.y <= s.x && s.y <= s.z { return .height }
        return .depth
    }

    /// Hur långt in i hindret produkten sticker, i mm.
    var penetrationMM: Double {
        overlap[deepestAxis]
    }
}
