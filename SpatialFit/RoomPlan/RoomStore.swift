//
//  RoomStore.swift
//  SpatialFit
//
//  Sparade rum på disk. Per rum skrivs två filer:
//
//    <id>.usdz  – RoomPlans mesh-export. Den rekonstruerade ytan, inte de
//                 parametriska boxarna, så att rummet går att titta på i 3D.
//    <id>.json  – `CapturedRoom` kodad. Boxarna finns kvar här, vilket gör att
//                 nischerna kan räknas om senare utan att kunden skannar igen.
//
//  Indexet (`index.json`) håller bara metadata. Det gör listan snabb att visa
//  utan att avkoda rumsgeometrin.
//

import Foundation
import Observation
import RoomPlan

@MainActor
@Observable
final class RoomStore {

    private(set) var rooms: [SavedRoom] = []

    private let directory: URL
    private let fileManager = FileManager.default

    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appending(path: "Rooms")
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: - Läsa

    func reload() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([SavedRoom].self, from: data) else {
            rooms = []
            return
        }
        rooms = stored.sorted { $0.scannedAt > $1.scannedAt }
    }

    func modelURL(for room: SavedRoom) -> URL {
        directory.appending(path: room.modelFilename)
    }

    /// Räknar om nischerna ur den sparade skanningen. Görs vid visning i
    /// stället för att cachas, så att förbättrad mätlogik slår igenom på gamla
    /// rum utan migrering.
    func niches(in room: SavedRoom) -> [ScannedNiche] {
        guard let captured = capturedRoom(for: room) else { return [] }
        return NicheFinder.niches(in: CapturedRoomReader.elements(from: captured))
    }

    private func capturedRoom(for room: SavedRoom) -> CapturedRoom? {
        let url = directory.appending(path: room.captureFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    // MARK: - Skriva

    /// Skriver USDZ:en först. Rummet hamnar i indexet bara om båda filerna gick
    /// att skriva, så listan aldrig visar ett rum som inte går att öppna.
    @discardableResult
    func save(_ captured: CapturedRoom, name: String) throws -> SavedRoom {
        let niches = NicheFinder.niches(in: CapturedRoomReader.elements(from: captured))
        let room = SavedRoom(name: name, nicheCount: niches.count)

        try captured.export(to: directory.appending(path: room.modelFilename),
                            exportOptions: .mesh)
        try JSONEncoder().encode(captured)
            .write(to: directory.appending(path: room.captureFilename))

        rooms.insert(room, at: 0)
        try writeIndex()
        return room
    }

    func rename(_ room: SavedRoom, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        rooms[index].name = trimmed
        try? writeIndex()
    }

    func delete(_ room: SavedRoom) {
        rooms.removeAll { $0.id == room.id }
        try? fileManager.removeItem(at: directory.appending(path: room.modelFilename))
        try? fileManager.removeItem(at: directory.appending(path: room.captureFilename))
        try? writeIndex()
    }

    // MARK: - Index

    private var indexURL: URL { directory.appending(path: "index.json") }

    private func writeIndex() throws {
        try JSONEncoder().encode(rooms).write(to: indexURL)
    }
}
