//
//  SavedRoom.swift
//  SpatialFit
//
//  Metadata om ett skannat rum som ligger kvar mellan appstarter. Själva
//  geometrin ligger i två filer bredvid: en USDZ för att titta på rummet och
//  en JSON med RoomPlans `CapturedRoom` för att kunna räkna om nischerna när
//  mätlogiken förbättras.
//
//  Ingen RoomPlan-import här – lagret ovanför gör tolkningen.
//

import Foundation

struct SavedRoom: Identifiable, Codable, Sendable, Hashable {

    let id: UUID
    var name: String
    let scannedAt: Date
    /// Vad `NicheFinder` hittade när rummet skannades. Visas i listan så att
    /// kunden ser om skanningen gav något innan hen öppnar rummet.
    var nicheCount: Int

    init(id: UUID = UUID(), name: String, scannedAt: Date = Date(), nicheCount: Int) {
        self.id = id
        self.name = name
        self.scannedAt = scannedAt
        self.nicheCount = nicheCount
    }

    /// Filnamn härleds ur id:t, så indexet aldrig kan peka fel.
    var modelFilename: String { "\(id.uuidString).usdz" }
    var captureFilename: String { "\(id.uuidString).json" }

    var scannedAtDescription: String {
        scannedAt.formatted(date: .abbreviated, time: .shortened)
    }
}
