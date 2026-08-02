//
//  RoomBakeModel.swift
//  SpatialFit
//
//  Bakningens tillstånd, skilt från vyn. `BakeService` rapporterar från en
//  bakgrundstråd, och en `View` är ett värde som inte går att skicka dit —
//  klassen är det som får ta emot.
//

import Foundation
import Observation

@MainActor
@Observable
final class RoomBakeModel {

    enum Phase: Equatable {
        case idle
        case working(String)
        case done(BakeService.Summary)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    var isWorking: Bool {
        if case .working = phase { true } else { false }
    }

    func bake(_ room: SavedRoom, in store: RoomStore, server: URL) async {
        phase = .working("Förbereder skanningen…")

        let service = BakeService(server: server)
        let files = store.scanFiles(for: room)
        let destination = store.directory(for: room)

        do {
            let summary = try await service.bake(uploading: files, into: destination) { message in
                Task { @MainActor in self.phase = .working(message) }
            }
            phase = .done(summary)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
