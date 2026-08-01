//
//  RoomScanView.swift
//  SpatialFit
//
//  Skanningsflödet: RoomPlans egen vy, sedan en lista över de nischer som
//  hittades. Vilken nisch kunden menar är en UI-fråga, inte en geometrisk –
//  därför väljer användaren, och `NicheFinder` gissar inte.
//

import SwiftUI
import RoomPlan

struct RoomScanView: View {

    /// Anropas med den nisch användaren pekade ut.
    let onPick: (ScannedNiche) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var scan = RoomScanModel()

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
        .onAppear { scan.start() }
    }

    @ViewBuilder
    private var content: some View {
        switch scan.phase {
        case .unsupported:
            message(icon: "iphone.slash",
                    title: "Enheten saknar LiDAR",
                    detail: "Skanning kräver en iPhone Pro eller iPad Pro. Demot kör vidare på mockad nischdata.")

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

        case .finished(let niches):
            if niches.isEmpty {
                message(icon: "questionmark.square.dashed",
                        title: "Hittade ingen nisch",
                        detail: "Skanningen behöver se två skåp eller vitvaror som står mot samma vägg med ett mellanrum emellan. Gå närmare och skanna om.")
            } else {
                nicheList(niches)
            }
        }
    }

    private var scanningHint: some View {
        Text("Gå långsamt längs väggen och håll skåpens sidor i bild.")
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
    }

    private func nicheList(_ niches: [ScannedNiche]) -> some View {
        List(niches) { found in
            Button {
                onPick(found)
                dismiss()
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(found.niche.dimensions.shortDescription)
                        .font(.headline)
                    Text("\(found.niche.label) · ±\(Units.format(found.niche.toleranceMM))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
