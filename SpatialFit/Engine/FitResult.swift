//
//  FitResult.swift
//  SpatialFit
//
//  Zon-logiken. Detta är produktens affärsregel och ska vara läsbar för en
//  kategorichef, inte bara för en utvecklare.
//

import Foundation

/// 🟢 / 🟡 / 🔴
enum FitZone: Int, Comparable, Sendable {
    case green = 0
    case yellow = 1
    case red = 2

    static func < (lhs: FitZone, rhs: FitZone) -> Bool { lhs.rawValue < rhs.rawValue }

    var symbol: String {
        switch self {
        case .green:  return "checkmark.circle.fill"
        case .yellow: return "exclamationmark.triangle.fill"
        case .red:    return "xmark.octagon.fill"
        }
    }

    var title: String {
        switch self {
        case .green:  return "PASSAR"
        case .yellow: return "TIGHT PASSFORM"
        case .red:    return "KOLLISIONSVARNING"
        }
    }
}

/// Hur strikt passformen bedöms. Kedjespecifik – Bauhaus kan vilja ha 20 mm
/// där en annan kedja nöjer sig med 10.
struct FitPolicy: Sendable {
    /// Minsta totala marginal (summan av båda sidor) för grön zon.
    var greenClearanceMM: Double = 15
    /// Vilka axlar som prövas. En fristående spis kan t.ex. tillåtas sticka ut
    /// i djupled – då plockar man bort `.depth` här.
    var evaluatedAxes: [Axis] = [.width, .height, .depth]
    /// Lägg mätosäkerheten från skanningen ovanpå gröngränsen. Med RoomPlan
    /// (±15 mm) betyder det att grön zon kräver 30 mm marginal.
    var addsScanTolerance: Bool = false

    static let standard = FitPolicy()
}

/// Passformen på en enskild axel.
struct AxisClearance: Identifiable, Equatable, Sendable {
    let axis: Axis
    /// Nischens fria mått.
    let availableMM: Double
    /// Produktens mått inkl. installationsmarginal.
    let requiredMM: Double
    /// Gränsen för grön zon på just denna axel.
    let greenThresholdMM: Double

    var id: String { axis.rawValue }

    /// Positivt = luft kvar. Negativt = produkten är för stor.
    var clearanceMM: Double { availableMM - requiredMM }

    var zone: FitZone {
        if clearanceMM < 0 { return .red }
        if clearanceMM < greenThresholdMM { return .yellow }
        return .green
    }

    /// Vid krock: hur mycket produkten sticker ut på VARJE sida (centrerad).
    var overhangPerSideMM: Double { max(0, -clearanceMM) / 2 }

    /// "+20 mm" / "-300 mm"
    var formattedClearance: String { Units.format(clearanceMM, signed: true) }
}

/// Motorns svar på frågan "passar den här produkten i den här nischen?".
struct FitResult: Equatable, Sendable {
    let product: Product
    let niche: Niche
    let axes: [AxisClearance]
    /// Faktiska överlappsvolymer mot skåp/väggar/bänkskivor.
    let intersections: [Intersection]

    /// Sämsta axeln avgör helhetsbedömningen.
    var zone: FitZone { axes.map(\.zone).max() ?? .green }

    var worstAxis: AxisClearance {
        axes.min { lhs, rhs in lhs.clearanceMM < rhs.clearanceMM } ?? axes[0]
    }

    var hasCollision: Bool { zone == .red }

    /// "KOLLISIONSVARNING"
    var headline: String { zone.title }

    /// Huvudmeningen i varningen.
    /// Röd:  "Produkten är +300 mm för bred för vald nisch"
    /// Gul:  "Endast 4 mm marginal i bredd – kontrollmät nischen"
    /// Grön: "20 mm marginal i bredd"
    var message: String {
        let axis = worstAxis
        switch zone {
        case .red:
            let excess = Units.format(abs(axis.clearanceMM), signed: true)
            return "Produkten är \(excess) för \(axis.axis.adjective) för vald nisch"
        case .yellow:
            return "Endast \(Units.format(axis.clearanceMM)) marginal i \(axis.axis.label.lowercased()) – kontrollmät nischen"
        case .green:
            return "\(Units.format(axis.clearanceMM)) marginal i \(axis.axis.label.lowercased())"
        }
    }

    /// Rad två i varningen: "Nisch 600 mm · Produkt 900 mm"
    var comparison: String {
        let axis = worstAxis
        return "Nisch \(Units.format(axis.availableMM)) · Produkt \(Units.format(axis.requiredMM))"
    }

    /// Vad säljaren ska göra härnäst.
    var recommendation: String? {
        switch zone {
        case .red:
            return "Välj en smalare modell eller bredda nischen med \(Units.format(abs(worstAxis.clearanceMM)))."
        case .yellow:
            var text = "Kontrollmät nischen på tre höjder innan order läggs."
            if niche.toleranceMM > 0 {
                text += " Skanningens osäkerhet är ±\(Units.format(niche.toleranceMM))."
            }
            return text
        case .green:
            return nil
        }
    }
}
