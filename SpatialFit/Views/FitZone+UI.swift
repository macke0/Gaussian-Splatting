//
//  FitZone+UI.swift
//  SpatialFit
//
//  Ett enda ställe där zonen får en färg. Håller 3D-scenen och UI:t i synk.
//

import SwiftUI

extension FitZone {
    var tint: Color {
        switch self {
        case .green:  return Color(red: 0.18, green: 0.78, blue: 0.42)
        case .yellow: return Color(red: 1.00, green: 0.74, blue: 0.10)
        case .red:    return Color(red: 1.00, green: 0.26, blue: 0.26)
        }
    }

    var badgeEmoji: String {
        switch self {
        case .green:  return "🟢"
        case .yellow: return "🟡"
        case .red:    return "🔴"
        }
    }

    var shortLabel: String {
        switch self {
        case .green:  return "OK"
        case .yellow: return "TIGHT"
        case .red:    return "KROCK"
        }
    }
}
