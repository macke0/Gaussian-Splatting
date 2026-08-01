//
//  Units.swift
//  SpatialFit
//
//  All produkt- och nischdata uttrycks i MILLIMETER (Double) – samma enhet som
//  PIM-systemen hos kedjorna levererar. RealityKit arbetar i METER (Float).
//  Konverteringen sker på exakt ett ställe: här. Ingen annan fil får dividera
//  med 1000.
//

import Foundation
import simd

enum Units {
    static let millimetersPerMeter: Double = 1000

    static func meters(fromMM mm: Double) -> Float {
        Float(mm / millimetersPerMeter)
    }

    static func millimeters(fromMeters m: Float) -> Double {
        Double(m) * millimetersPerMeter
    }

    /// "600 mm", "+20 mm", "-300 mm". Avrundar till hel millimeter.
    static func format(_ mm: Double, signed: Bool = false) -> String {
        let rounded = (mm).rounded()
        let value = abs(rounded) < 0.5 ? 0 : rounded // undvik "-0 mm"
        if signed {
            let sign = value < 0 ? "-" : "+"
            return "\(sign)\(Int(abs(value))) mm"
        }
        return "\(Int(value)) mm"
    }
}

extension Double {
    /// Millimeter -> meter, för RealityKit.
    var asMeters: Float { Units.meters(fromMM: self) }
}

extension Float {
    /// Meter -> millimeter, för UI och PIM-jämförelser.
    var asMillimeters: Double { Units.millimeters(fromMeters: self) }
}

// MARK: - Axlar

/// De tre axlar som passformen prövas mot. Mappar 1:1 mot RealityKits X/Y/Z.
enum Axis: String, CaseIterable, Identifiable, Sendable {
    case width   // X
    case height  // Y
    case depth   // Z

    var id: String { rawValue }

    /// "Bredd" – används i mätlistor.
    var label: String {
        switch self {
        case .width:  return "Bredd"
        case .height: return "Höjd"
        case .depth:  return "Djup"
        }
    }

    /// "bred" – används i varningstexter: "Produkten är +300 mm för bred".
    var adjective: String {
        switch self {
        case .width:  return "bred"
        case .height: return "hög"
        case .depth:  return "djup"
        }
    }

    var simdIndex: Int {
        switch self {
        case .width:  return 0
        case .height: return 1
        case .depth:  return 2
        }
    }
}

// MARK: - Dimensioner

/// En axelriktad bounding box i millimeter. Detta är exakt det som kommer ur
/// ett PIM-system (b x h x d) och exakt det RoomPlan ger oss för en nisch.
struct Dimensions3D: Equatable, Hashable, Sendable {
    var width: Double
    var height: Double
    var depth: Double

    init(width: Double, height: Double, depth: Double) {
        self.width = width
        self.height = height
        self.depth = depth
    }

    /// Bekvämlighet: `Dimensions3D(600, 900, 650)`
    init(_ width: Double, _ height: Double, _ depth: Double) {
        self.init(width: width, height: height, depth: depth)
    }

    subscript(axis: Axis) -> Double {
        get {
            switch axis {
            case .width:  return width
            case .height: return height
            case .depth:  return depth
            }
        }
        set {
            switch axis {
            case .width:  width = newValue
            case .height: height = newValue
            case .depth:  depth = newValue
            }
        }
    }

    /// Storlek i meter, redo för `MeshResource.generateBox(size:)`.
    var metersSize: SIMD3<Float> {
        SIMD3(width.asMeters, height.asMeters, depth.asMeters)
    }

    /// "600 × 900 × 650 mm"
    var shortDescription: String {
        "\(Int(width.rounded())) × \(Int(height.rounded())) × \(Int(depth.rounded())) mm"
    }

    init(metersSize: SIMD3<Float>) {
        self.init(width: metersSize.x.asMillimeters,
                  height: metersSize.y.asMillimeters,
                  depth: metersSize.z.asMillimeters)
    }
}
