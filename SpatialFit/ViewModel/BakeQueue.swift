//
//  BakeQueue.swift
//  SpatialFit
//
//  Bakningarna som pågår, en per rum.
//
//  Den låg förut som `@State` i bakningsarket, vilket band kunden vid en modal i
//  upp till en kvart: stängde man arket dog uppgiften och arbetet var bortkastat.
//  Måtten kunden kom för är klara direkt och har aldrig gått via servern — det är
//  bara utseendet som tar tid, och det får komma efter.
//
//  Kön äger därför uppgifterna, inte vyn. Jobbets id ligger dessutom på disk hos
//  rummet, så att en avslutad app kan koppla upp sig mot samma bakning igen i
//  stället för att ladda upp skanningen en gång till.
//

import Foundation
import Observation

@MainActor
@Observable
final class BakeQueue {

    enum Phase: Equatable {
        case working(String)
        case done(BakeService.Summary)
        case failed(String)
    }

    private(set) var phases: [SavedRoom.ID: Phase] = [:]

    @ObservationIgnored
    private var tasks: [SavedRoom.ID: Task<Void, Never>] = [:]

    func phase(for room: SavedRoom) -> Phase? { phases[room.id] }

    func isWorking(_ room: SavedRoom) -> Bool {
        if case .working = phases[room.id] { true } else { false }
    }

    /// Laddar upp skanningen och lämnar sedan bakningen åt sig själv. Att vyn
    /// försvinner spelar ingen roll: uppgiften ägs härifrån.
    func bake(_ room: SavedRoom, in store: RoomStore, server: URL,
              colorSource: BakeService.ColorSource) {
        guard tasks[room.id] == nil else { return }

        phases[room.id] = .working("Förbereder skanningen…")
        tasks[room.id] = Task { [weak self] in
            let service = BakeService(server: server)
            do {
                let job = try await service.start(uploading: store.scanFiles(for: room),
                                                  colorSource: colorSource)
                store.setPendingBake(PendingBake(job: job, server: server, startedAt: .now),
                                     for: room)
                await self?.follow(job, of: room, in: store, using: service)
            } catch {
                self?.finish(room, with: .failed(error.localizedDescription), in: store)
            }
        }
    }

    /// Tar upp de bakningar som pågick när appen senast stängdes. Anropas när
    /// biblioteket visas; ett jobb som servern glömt faller ut som ett fel.
    func resumePending(in store: RoomStore) {
        for room in store.rooms {
            guard let pending = store.pendingBake(for: room), tasks[room.id] == nil else { continue }

            phases[room.id] = .working("Servern bakar rummet…")
            let service = BakeService(server: pending.server)
            tasks[room.id] = Task { [weak self] in
                await self?.follow(pending.job, of: room, in: store, using: service)
            }
        }
    }

    // MARK: - Väntan

    private func follow(_ job: String, of room: SavedRoom, in store: RoomStore,
                        using service: BakeService) async {
        do {
            let summary = try await service.collect(job, into: store.directory(for: room)) { message in
                Task { @MainActor [weak self] in self?.phases[room.id] = .working(message) }
            }
            finish(room, with: .done(summary), in: store)
        } catch {
            // Ett tapppat nät mitt i en kvartslång bakning får inte kosta kunden
            // en ny uppladdning. Jobbet ligger kvar på servern, så id:t sparas
            // och nästa gång biblioteket visas hämtas resultatet i stället.
            finish(room, with: .failed(error.localizedDescription), in: store,
                   keepingJob: Self.isTemporary(error))
        }
    }

    private func finish(_ room: SavedRoom, with phase: Phase, in store: RoomStore,
                        keepingJob: Bool = false) {
        if !keepingJob { store.setPendingBake(nil, for: room) }
        tasks[room.id] = nil
        phases[room.id] = phase
    }

    /// Om felet är värt att försöka igen. Servern som säger nej har bestämt sig;
    /// ett brutet nät har det inte.
    private static func isTemporary(_ error: Error) -> Bool {
        switch error {
        case is BakeService.Failure: false
        default: error is URLError
        }
    }
}
