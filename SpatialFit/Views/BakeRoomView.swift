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
    @AppStorage("bakeColorSource") private var colorSource = BakeService.ColorSource.blend.rawValue
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
                    Picker("Färg", selection: $colorSource) {
                        ForEach(BakeService.ColorSource.allCases) { source in
                            Text(source.label).tag(source.rawValue)
                        }
                    }
                    .disabled(model.isWorking)
                } footer: {
                    Text("Gaussian splatting fyller hål och jämnar ut skarvar, men "
                         + "kräver att servern har ett grafikkort.")
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
            if let missing {
                Label(missing, systemImage: "exclamationmark.triangle")
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

    private var canBake: Bool { missing == nil }

    /// Vad som fattas, om något. Att peka ut vilket av de två spar en skanning:
    /// en saknad yta och saknade foton kräver olika saker av kunden.
    private var missing: String? {
        switch (store.sceneMesh(for: room) != nil, store.keyframes(for: room).isEmpty) {
        case (true, false):
            nil
        case (false, false):
            "Rummet saknar den täta ytan — det sparades som RoomPlans lådor. Skanna om det."
        case (true, true):
            "Rummet saknar foton att måla med. Skanna om det."
        case (false, true):
            "Rummet saknar både tät yta och foton. Skanna om det."
        }
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
            await model.bake(room, in: store, server: server,
                             colorSource: .init(rawValue: colorSource) ?? .blend)
            if case .done = model.phase { onFinished() }
        }
    }
}
