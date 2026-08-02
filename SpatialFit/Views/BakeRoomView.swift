//
//  BakeRoomView.swift
//  SpatialFit
//
//  Skicka rummet till bakningsservern och vänta ut den.
//
//  Adressen sitter i appen, inte i en inställningsvy: servern är en maskin i ett
//  rum, och den som ställer in den är samma person som just har skannat.
//

import SwiftUI

struct BakeRoomView: View {

    let room: SavedRoom
    let store: RoomStore
    /// Anropas när ett bakat rum ligger på disk, så vyn bakom kan läsa om det.
    var onFinished: () -> Void

    @AppStorage("bakeServer") private var address = ""
    @State private var model = RoomBakeModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8000", text: $address)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.isWorking)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Bakningen sker på en dator i butiken. Telefonen mäter, "
                         + "servern målar.")
                }

                Section {
                    LabeledContent("Foton", value: "\(store.keyframes(for: room).count)")
                    LabeledContent("Yta", value: surfaceDescription)
                }

                Section { status }
            }
            .navigationTitle("Baka rummet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") { dismiss() }
                        .disabled(model.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Baka") { start() }
                        .disabled(server == nil || model.isWorking || !canBake)
                }
            }
            .interactiveDismissDisabled(model.isWorking)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch model.phase {
        case .idle:
            if !canBake {
                Label("Rummet saknar tät yta eller foton. Skanna om det.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        case .working(let message):
            HStack(spacing: 12) {
                ProgressView()
                Text(message)
            }
        case .done(let summary):
            VStack(alignment: .leading, spacing: 6) {
                Label("Rummet är målat.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
                Text("\(summary.triangleCount) trianglar, "
                     + "\(Int(summary.seenFraction * 100)) % av ytan fotograferad.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .failed(let reason):
            Label(reason, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private var canBake: Bool {
        store.sceneMesh(for: room) != nil && !store.keyframes(for: room).isEmpty
    }

    private var surfaceDescription: String {
        guard let mesh = store.sceneMesh(for: room) else { return "saknas" }
        return "\(mesh.triangleCount) trianglar"
    }

    /// Tomt fält och rena stavfel ska inte bli en uppladdning till ingenstans.
    private var server: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed), url.scheme != nil, url.host() != nil else {
            return nil
        }
        return url
    }

    private func start() {
        guard let server else { return }
        Task {
            await model.bake(room, in: store, server: server)
            if case .done = model.phase { onFinished() }
        }
    }
}
