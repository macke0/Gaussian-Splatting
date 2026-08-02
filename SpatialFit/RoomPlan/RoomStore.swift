//
//  RoomStore.swift
//  SpatialFit
//
//  Sparade rum på disk. Varje rum får en egen mapp:
//
//    <id>/room.usdz       RoomPlans mesh-export. Den rekonstruerade ytan, inte
//                         de parametriska boxarna.
//    <id>/room.json       `CapturedRoom` kodad. Boxarna finns kvar här, så att
//                         nischerna kan räknas om utan att kunden skannar om.
//    <id>/keyframes.json  Kamerornas placering.
//    <id>/kfN.jpg/.depth  Fotona och LiDAR-djupet som målar rummet.
//
//  Indexet (`index.json`) håller bara metadata, så listan går att visa utan
//  att avkoda rumsgeometrin.
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
        // Rum vars mapp saknas kan inte öppnas. De listas inte, så kunden inte
        // klickar sig in i ett tomt rum.
        rooms = stored
            .filter { fileManager.fileExists(atPath: modelURL(for: $0).path) }
            .sorted { $0.scannedAt > $1.scannedAt }
    }

    func directory(for room: SavedRoom) -> URL {
        directory.appending(path: room.directoryName)
    }

    func modelURL(for room: SavedRoom) -> URL {
        directory(for: room).appending(path: SavedRoom.modelFilename)
    }

    func keyframes(for room: SavedRoom) -> [Keyframe] {
        let url = directory(for: room).appending(path: SavedRoom.keyframeFilename)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([Keyframe].self, from: data) else { return [] }
        return stored
    }

    /// Räknar om nischerna ur den sparade skanningen. Görs vid visning i
    /// stället för att cachas, så att förbättrad mätlogik slår igenom på gamla
    /// rum utan migrering.
    func niches(in room: SavedRoom) -> [ScannedNiche] {
        guard let captured = capturedRoom(for: room) else { return [] }
        return NicheFinder.niches(in: CapturedRoomReader.elements(from: captured))
    }

    private func capturedRoom(for room: SavedRoom) -> CapturedRoom? {
        let url = directory(for: room).appending(path: SavedRoom.captureFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(CapturedRoom.self, from: data)
    }

    // MARK: - Skriva

    /// Fotona ligger i en temporär mapp under skanningen, eftersom rummets id
    /// inte finns förrän här. De flyttas in, så inget kopieras i onödan.
    @discardableResult
    func save(_ captured: CapturedRoom,
              name: String,
              keyframes: [Keyframe] = [],
              photoDirectory: URL? = nil) throws -> SavedRoom {
        let niches = NicheFinder.niches(in: CapturedRoomReader.elements(from: captured))
        let room = SavedRoom(name: name,
                             nicheCount: niches.count,
                             hasPhotos: !keyframes.isEmpty)
        let folder = directory(for: room)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            try captured.export(to: folder.appending(path: SavedRoom.modelFilename),
                                exportOptions: .mesh)
            try JSONEncoder().encode(captured)
                .write(to: folder.appending(path: SavedRoom.captureFilename))

            if !keyframes.isEmpty, let photoDirectory {
                try movePhotos(keyframes, from: photoDirectory, to: folder)
                try JSONEncoder().encode(keyframes)
                    .write(to: folder.appending(path: SavedRoom.keyframeFilename))
            }
        } catch {
            // Halvskrivna rum ska inte hamna i listan.
            try? fileManager.removeItem(at: folder)
            throw error
        }

        rooms.insert(room, at: 0)
        try writeIndex()
        return room
    }

    private func movePhotos(_ keyframes: [Keyframe], from source: URL, to destination: URL) throws {
        for keyframe in keyframes {
            for filename in [keyframe.imageFilename, keyframe.depthFilename] {
                let origin = source.appending(path: filename)
                guard fileManager.fileExists(atPath: origin.path) else { continue }
                try fileManager.moveItem(at: origin, to: destination.appending(path: filename))
            }
        }
        try? fileManager.removeItem(at: source)
    }

    func rename(_ room: SavedRoom, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = rooms.firstIndex(where: { $0.id == room.id }) else { return }
        rooms[index].name = trimmed
        try? writeIndex()
    }

    func delete(_ room: SavedRoom) {
        rooms.removeAll { $0.id == room.id }
        try? fileManager.removeItem(at: directory(for: room))
        try? writeIndex()
    }

    // MARK: - Index

    private var indexURL: URL { directory.appending(path: "index.json") }

    private func writeIndex() throws {
        try JSONEncoder().encode(rooms).write(to: indexURL)
    }
}
