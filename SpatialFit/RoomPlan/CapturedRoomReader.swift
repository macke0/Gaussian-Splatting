//
//  CapturedRoomReader.swift
//  SpatialFit
//
//  CapturedRoom → [RoomElement]. Enda stället i appen som importerar RoomPlan.
//
//  Översättningen är avsiktligt tunn och avsiktligt grov. RoomPlan skiljer på
//  soffa, fåtölj och säng; nischsökningen bryr sig bara om att de tar plats.
//  Den finkorniga kategorin följer med som `detail` för etiketter i UI, och
//  ingenstans annars.
//

import Foundation
import RoomPlan
import simd

enum CapturedRoomReader {

    /// Rummet som orienterade lådor i ARKits världskoordinater.
    static func elements(from room: CapturedRoom) -> [RoomElement] {
        var elements: [RoomElement] = []

        elements += room.walls.map { surface(from: $0, category: .wall, detail: "vägg") }
        elements += room.floors.map { surface(from: $0, category: .floor, detail: "golv") }
        elements += room.doors.map { surface(from: $0, category: .opening, detail: "dörr") }
        elements += room.windows.map { surface(from: $0, category: .opening, detail: "fönster") }
        elements += room.openings.map { surface(from: $0, category: .opening, detail: "öppning") }

        elements += room.objects.map { object in
            RoomElement(id: object.identifier.uuidString,
                        category: .furniture,
                        transform: object.transform,
                        dimensions: object.dimensions,
                        detail: label(for: object.category))
        }

        return elements
    }

    private static func surface(from surface: CapturedRoom.Surface,
                                category: RoomElementCategory,
                                detail: String) -> RoomElement {
        RoomElement(id: surface.identifier.uuidString,
                    category: category,
                    transform: surface.transform,
                    dimensions: surface.dimensions,
                    detail: detail)
    }

    /// Svensk etikett för de kategorier som faktiskt dyker upp i ett kök eller
    /// badrum. Övriga blir "möbel" – de är ändå bara hinder.
    private static func label(for category: CapturedRoom.Object.Category) -> String {
        switch category {
        case .storage:      return "skåp"
        case .refrigerator: return "kyl"
        case .stove:        return "spis"
        case .oven:         return "ugn"
        case .dishwasher:   return "diskmaskin"
        case .washerDryer:  return "tvättmaskin"
        case .sink:         return "diskbänk"
        case .table:        return "bord"
        case .bathtub:      return "badkar"
        case .toilet:       return "toalett"
        default:            return "möbel"
        }
    }
}

/// Nischer ur en färdig RoomPlan-skanning.
///
/// `Engine/` ändras inte en rad för att koppla in det här – hela poängen med
/// `NicheSource`. Det som tillkommer är `worldFromNiche`, som scenlagret
/// behöver för att ankra nischen i passthrough-vyn.
struct RoomPlanNicheSource: NicheSource {
    let scanned: ScannedNiche

    var niche: Niche { scanned.niche }
    var obstacles: [Obstacle] { scanned.obstacles }
    var worldFromNiche: simd_float4x4 { scanned.worldFromNiche }

    /// Alla nischer i rummet, störst först. Tom om skanningen inte hittade
    /// två skåp som flankerar ett mellanrum.
    static func niches(in room: CapturedRoom,
                       options: NicheFinder.Options = NicheFinder.Options()) -> [RoomPlanNicheSource] {
        NicheFinder.niches(in: CapturedRoomReader.elements(from: room), options: options)
            .map { RoomPlanNicheSource(scanned: $0) }
    }
}
