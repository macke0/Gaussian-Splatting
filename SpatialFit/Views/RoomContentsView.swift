//
//  RoomContentsView.swift
//  SpatialFit
//
//  Vad skanningen hittade i rummet, med mått.
//
//  Poängen är att visa att rummet inte bara är en yta att titta på: RoomPlan
//  har redan klassat pjäserna, så appen vet att det där är en spis och att den
//  är 596 mm bred. Det är den kunskapen som gör det möjligt att byta ut den
//  mot en produkt ur PIM — texturen säger ingenting om saken.
//
//  Måtten kommer från skanningen och är sanning. Beskrivningen kommer från en
//  bildmodell och är en gissning; de två får aldrig se likadana ut i vyn.
//

import SwiftUI

struct RoomContentsView: View {

    let room: SavedRoom
    let store: RoomStore

    @AppStorage("bakeServer") private var address = ""
    @Environment(\.dismiss) private var dismiss

    @State private var descriptions: [String: IdentifyService.Description] = [:]
    @State private var missing: Set<String> = []
    @State private var busy = false
    @State private var failure: String?

    private var furniture: [RoomElement] {
        store.elements(in: room)
            .filter { $0.category == .furniture }
            .sorted { ($0.detail ?? "") < ($1.detail ?? "") }
    }

    private var server: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    var body: some View {
        NavigationStack {
            Group {
                if furniture.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .navigationTitle("I rummet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Klar") { dismiss() }
                }
                if !furniture.isEmpty, server != nil, room.hasPhotos {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Beskriv") { Task { await identifyAll() } }
                            .disabled(busy)
                    }
                }
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Inget igenkänt", systemImage: "questionmark.square.dashed")
        } description: {
            Text("Skanningen hittade inga skåp eller vitvaror. "
                 + "Gå långsammare längs bänken när du skannar om.")
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(furniture) { element in
                    row(element)
                }
            } footer: {
                footer
            }
        }
    }

    @ViewBuilder
    private func row(_ element: RoomElement) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(element.detail ?? "möbel")
                    .textCase(.uppercase)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(Dimensions3D(metersSize: element.dimensions).shortDescription)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if let described = descriptions[element.id] {
                // Osäkra svar märks ut. Ett påhittat "rostfri induktionshäll"
                // som ser lika säkert ut som måttet är värre än inget svar.
                Label(described.summary,
                      systemImage: described.confidence < IdentifyService.Description.uncertain
                        ? "questionmark.circle" : "sparkles")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if missing.contains(element.id) {
                Text("Inget foto visar hela pjäsen.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var footer: some View {
        if let failure {
            Text(failure).foregroundStyle(.orange)
        } else if busy {
            Text("Frågar servern vad pjäserna är…")
        } else if server == nil {
            Text("Måtten kommer från skanningen. För att också få veta vad "
                 + "pjäserna är för sort behövs en serveradress — den ställs in "
                 + "under Baka rummet.")
        } else {
            Text("Måtten kommer från skanningen och är mätta. Beskrivningarna "
                 + "kommer från en bildmodell och är gissningar.")
        }
    }

    // MARK: - Identifiering

    /// En pjäs i taget, så listan fylls i medan man tittar på den. Modellen tar
    /// sekunder per bild och ett kök har tio skåp.
    private func identifyAll() async {
        busy = true
        failure = nil
        defer { busy = false }

        guard let server else { return }
        let service = IdentifyService(server: server)
        let keyframes = store.keyframes(for: room)
        let directory = store.directory(for: room)

        for element in furniture {
            do {
                descriptions[element.id] = try await service.describe(element,
                                                                      keyframes: keyframes,
                                                                      directory: directory)
                missing.remove(element.id)
            } catch IdentifyService.Failure.noPhotoShowsIt {
                missing.insert(element.id)
            } catch {
                // Ett trasigt anrop stoppar hela raden: är servern nere blir
                // resten också det, och tio likadana fel hjälper ingen.
                failure = error.localizedDescription
                return
            }
        }
    }
}

private extension IdentifyService.Description {
    /// "rostfri induktionshäll" — utan att upprepa vad RoomPlan redan sagt.
    var summary: String {
        detail.isEmpty ? kind : (kind.isEmpty ? detail : "\(kind) — \(detail)")
    }
}
