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

    /// Den täta LiDAR-ytan, om skanningen fick tag i den. `nil` betyder att
    /// bara RoomPlans tolkning finns att visa.
    func sceneMesh(for room: SavedRoom) -> SceneMesh? {
        let url = directory(for: room).appending(path: SavedRoom.sceneMeshFilename)
        guard let data = try? Data(contentsOf: url), let mesh = SceneMesh(data: data),
              !mesh.isEmpty else { return nil }
        return mesh
    }

    /// Om det bakade rummet från servern hämtats hem.
    func hasBakedRoom(for room: SavedRoom) -> Bool {
        fileManager.fileExists(atPath: directory(for: room)
            .appending(path: TexturedMesh.meshFilename).path)
    }

    /// Splatten, om servern tränade fram en. Den är bara till för att titta på —
    /// måtten kommer från meshen.
    func splatURL(for room: SavedRoom) -> URL? {
        let url = directory(for: room).appending(path: BakeService.splatFilename)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Bakningen som pågår på servern för rummet, om någon gör det. Ligger på
    /// disk och inte i minnet: en bakning tar en kvart, och appen kan mycket väl
    /// avslutas under tiden. Jobbet lever ändå kvar på servern.
    func pendingBake(for room: SavedRoom) -> PendingBake? {
        let url = directory(for: room).appending(path: Self.pendingBakeFilename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PendingBake.self, from: data)
    }

    func setPendingBake(_ bake: PendingBake?, for room: SavedRoom) {
        let url = directory(for: room).appending(path: Self.pendingBakeFilename)
        guard let bake else {
            try? fileManager.removeItem(at: url)
            return
        }
        try? JSONEncoder().encode(bake).write(to: url, options: .atomic)
    }

    private static let pendingBakeFilename = "bake.job"

    /// Filerna bakningsservern behöver. USDZ:n och `CapturedRoom` stannar på
    /// telefonen — servern målar ytan, den tolkar inte rummet.
    func scanFiles(for room: SavedRoom) -> [URL] {
        let folder = directory(for: room)
        var files = [folder.appending(path: SavedRoom.sceneMeshFilename),
                     folder.appending(path: SavedRoom.keyframeFilename)]
        for keyframe in keyframes(for: room) {
            files.append(folder.appending(path: keyframe.imageFilename))
            files.append(folder.appending(path: keyframe.depthFilename))
        }
        return files
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
        NicheFinder.niches(in: elements(in: room))
    }

    /// Rummets beståndsdelar som orienterade lådor, med RoomPlans klassning
    /// kvar i `detail`. Det är härifrån vi vet att något ÄR en spis, och hur
    /// stor just den spisen är.
    func elements(in room: SavedRoom) -> [RoomElement] {
        guard let captured = capturedRoom(for: room) else { return [] }
        return CapturedRoomReader.elements(from: captured)
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
              photoDirectory: URL? = nil,
              sceneMesh: SceneMesh = SceneMesh()) throws -> SavedRoom {
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

            if !sceneMesh.isEmpty {
                try sceneMesh.encoded()
                    .write(to: folder.appending(path: SavedRoom.sceneMeshFilename))
            }

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
