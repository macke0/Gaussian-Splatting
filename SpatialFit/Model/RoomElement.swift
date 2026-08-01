//
//  RoomElement.swift
//  SpatialFit
//
//  Ett skannat rum, uttryckt utan att någonting importerar RoomPlan.
//
//  RoomPlan levererar `CapturedRoom.Surface` och `CapturedRoom.Object` – båda
//  med en `transform` och en `dimensions`, dvs. orienterade lådor i världen.
//  `RoomElement` är exakt den formen och ingenting mer. Vinsten är att
//  nischsökningen blir ren geometri som går att testa mot ett påhittat rum,
//  och att RoomPlan bara rörs på ett enda ställe (`RoomPlan/CapturedRoomReader`).
//
//  Ett element är en OBB: `transform`-kolumnerna 0/1/2 är elementets egna
//  axlar, kolumn 3 dess mittpunkt, och `dimensions` dess storlek LÄNGS DE
//  AXLARNA. Ett kök som står snett i rummet beskrivs alltså korrekt här –
//  det är först när vi projicerar ner i nischens system som axelriktningen
//  återinförs, och då är den giltig.
//

import Foundation
import simd

/// Vad RoomPlan hittade. Grovare än RoomPlans egen kategorilista med flit:
/// motorn bryr sig om ifall något är en vägg, ett golv, en öppning eller en
/// pjäs som tar plats – inte om pjäsen är en soffa eller en fåtölj.
enum RoomElementCategory: String, Sendable {
    case wall
    case floor
    /// Dörr, fönster eller öppning. Tar inte plats, men flankerar inte heller
    /// en nisch – en spis kan inte stå med sidan mot ett dörrhål.
    case opening
    /// Skåp, bänkar, vitvaror: det som bildar nischens sidor.
    case furniture

    var obstacleKind: ObstacleKind {
        switch self {
        case .wall:      return .wall
        case .floor:     return .floor
        case .opening:   return .wall
        case .furniture: return .cabinet
        }
    }

    /// Golvet står produkten på – det ska aldrig larma som krock.
    var isCollidable: Bool { self != .floor }
}

/// En orienterad låda ur skanningen, meter.
struct RoomElement: Identifiable, Equatable, Sendable {
    let id: String
    let category: RoomElementCategory
    /// Lokalt → världen.
    let transform: simd_float4x4
    /// Storlek längs elementets egna axlar.
    let dimensions: SIMD3<Float>
    /// RoomPlans egen kategoristräng, när den finns. Bara för etiketter i UI.
    var detail: String?

    var center: SIMD3<Float> {
        let c = transform.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    /// Elementets `index`:e egenaxel som enhetsvektor.
    func localAxis(_ index: Int) -> SIMD3<Float> {
        let c = transform[index]
        let v = SIMD3<Float>(c.x, c.y, c.z)
        let length = simd_length(v)
        return length > 1e-6 ? v / length : SIMD3(0, 0, 0)
    }

    /// Hur långt lådan sträcker sig från sin mittpunkt längs en godtycklig
    /// riktning. Summan av projektionerna av de tre halvaxlarna – standard-
    /// projektionen av en OBB, och det som gör att ett vridet skåp får rätt
    /// bredd även när vi mäter längs väggen i stället för längs skåpet.
    func halfExtent(along direction: SIMD3<Float>) -> Float {
        var sum: Float = 0
        for index in 0..<3 {
            sum += abs(simd_dot(localAxis(index), direction)) * dimensions[index] / 2
        }
        return sum
    }
}
