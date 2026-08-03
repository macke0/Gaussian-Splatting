//
//  BakeRoomView.swift
//  SpatialFit
//
//  Skicka rummet till bakningsservern.
//
//  Arket väntar inte ut bakningen — det lämnar över den till `BakeQueue` och
//  stänger. Att måla rummet tar minuter, och kunden har redan fått sina mått.
//
//  Adressen sitter i appen, inte i en inställningsvy: servern är en maskin i ett
//  rum, och den som ställer in den är samma person som just har skannat.
//

import SwiftUI

struct BakeRoomView: View {

    let room: SavedRoom
    let store: RoomStore
    let queue: BakeQueue

    @AppStorage("bakeServer") private var address = ""
    @AppStorage("bakeColorSource") private var colorSource = BakeService.ColorSource.blend.rawValue
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
                } header: {
                    Text("Server")
                } footer: {
                    // En låst Baka-knapp utan förklaring läses som att servern
                    // är nere. Den vanligaste orsaken är att http:// glömts —
                    // utan schema och värd finns ingen adress att ladda upp till.
                    if address.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Bakningen sker på en dator i butiken. Telefonen "
                             + "mäter, servern målar.")
                    } else if server == nil {
                        Text("Adressen behöver både http:// och en värd, som "
                             + "http://192.168.1.20:8000.")
                            .foregroundStyle(.orange)
                    } else {
                        Text("Servern kontaktas först när du trycker Baka.")
                    }
                }

                Section {
                    Picker("Färg", selection: $colorSource) {
                        ForEach(BakeService.ColorSource.allCases) { source in
                            Text(source.label).tag(source.rawValue)
                        }
                    }
                } footer: {
                    Text(colorSource == BakeService.ColorSource.splat.rawValue
                         ? "Servern tränar en gaussian splat, vilket tar omkring en "
                           + "kvart men ger den skarpaste bilden av rummet. Kräver "
                           + "ett grafikkort."
                         : "Fotona vägs ihop per yta. Tar ett par minuter och går "
                           + "på vilken dator som helst.")
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
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Baka") { start() }
                        .disabled(server == nil || queue.isWorking(room) || !canBake)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if queue.isWorking(room) {
            Label("Rummet målas redan. Du kan stänga och fortsätta använda appen.",
                  systemImage: "paintbrush")
                .foregroundStyle(.secondary)
        } else if let missing {
            Label(missing, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else {
            Text("Bakningen sköter sig själv. Du kan stänga appen under tiden — "
                 + "rummet är målat nästa gång du öppnar det.")
                .font(.footnote)
                .foregroundStyle(.secondary)
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

    /// Lämnar över till kön och stänger. Det finns inget mer att titta på här:
    /// resten syns i rumsvyn, som går att lämna.
    private func start() {
        guard let server else { return }
        queue.bake(room, in: store, server: server,
                   colorSource: .init(rawValue: colorSource) ?? .blend)
        dismiss()
    }
}
