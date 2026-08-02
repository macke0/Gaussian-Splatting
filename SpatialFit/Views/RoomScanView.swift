//
//  RoomScanView.swift
//  SpatialFit
//
//  Skanningsflödet: RoomPlans egen vy, sedan en sammanfattning där rummet får
//  ett namn och sparas. Nischvalet sker inte här längre – det hör hemma när
//  kunden ska placera en produkt, inte när rummet mäts upp.
//

import SwiftUI
import RoomPlan

struct RoomScanView: View {

    let store: RoomStore
    /// Anropas med det sparade rummet, så att biblioteket kan öppna det direkt.
    var onSaved: (SavedRoom) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var scan = RoomScanModel()
    @State private var name = ""
    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Skanna rummet")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Avbryt") {
                            scan.cancel()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if case .scanning = scan.phase {
                            Button("Klar") { scan.finish() }
                        }
                    }
                }
        }
        .onAppear {
            name = "Rum \(store.rooms.count + 1)"
            scan.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scan.phase {
        case .unsupported:
            message(icon: "iphone.slash",
                    title: "Enheten saknar LiDAR",
                    detail: "Skanning kräver en iPhone Pro eller iPad Pro.")

        case .scanning:
            if let captureView = scan.captureView {
                CaptureViewBridge(captureView: captureView)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) { scanningHint }
            }

        case .processing:
            ProgressView("Bearbetar skanningen…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let reason):
            message(icon: "exclamationmark.triangle",
                    title: "Skanningen misslyckades",
                    detail: reason)

        case .finished(let captured, let niches):
            summary(captured: captured, niches: niches)
        }
    }

    private var scanningHint: some View {
        Text("Gå långsamt runt rummet. Kameran fotograferar samtidigt, så håll väggar och möbler väl belysta i bild.")
            .font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
    }

    private func summary(captured: CapturedRoom, niches: [ScannedNiche]) -> some View {
        Form {
            Section("Namn") {
                TextField("Namn på rummet", text: $name)
            }

            Section("Skanningen") {
                LabeledContent("Väggar", value: "\(captured.walls.count)")
                LabeledContent("Möbler och vitvaror", value: "\(captured.objects.count)")
                LabeledContent("Nischer", value: "\(niches.count)")
                LabeledContent("Foton att måla med", value: "\(scan.keyframes.count)")
            }

            if let saveError {
                Section {
                    Text(saveError)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button("Spara rummet") { save(captured) }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func save(_ captured: CapturedRoom) {
        do {
            let saved = try store.save(captured,
                                       name: name.trimmingCharacters(in: .whitespaces),
                                       keyframes: scan.keyframes,
                                       photoDirectory: scan.photoDirectory)
            onSaved(saved)
            dismiss()
        } catch {
            saveError = "Kunde inte spara rummet: \(error.localizedDescription)"
        }
    }

    private func message(icon: String, title: String, detail: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        }
    }
}

/// RoomPlans `RoomCaptureView` är en UIView. Bryggan äger den inte – den ligger
/// i `RoomScanModel`, så att sessionen överlever att SwiftUI bygger om vyn.
private struct CaptureViewBridge: UIViewRepresentable {
    let captureView: RoomCaptureView

    func makeUIView(context: Context) -> RoomCaptureView { captureView }
    func updateUIView(_ uiView: RoomCaptureView, context: Context) {}
}
