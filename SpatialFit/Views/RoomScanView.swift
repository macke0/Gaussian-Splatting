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
    /// Hur stor del av ytan fotona faktiskt täcker. Mäts här och inte först i
    /// rumsvyn, för det här är sista stunden kunden står kvar i rummet och kan
    /// fylla i det som fattas.
    @State private var coverage: SurfaceCoverage.Report?

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
                    .overlay(alignment: .topTrailing) { liveCoverage }
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

    /// Kartan över vad kameran hunnit se, medan den fortfarande går att fylla i.
    ///
    /// Den kan inte visa rött: en yta som aldrig varit i bild har inga
    /// djuppunkter och syns som tomrum, inte som fel. Det tomma är därför lika
    /// viktigt att läsa som det gula, och texten säger det rakt ut.
    @ViewBuilder
    private var liveCoverage: some View {
        if !scan.coverageMap.tiles.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                CoverageMapView(map: scan.coverageMap,
                                position: scan.devicePosition,
                                heading: scan.deviceHeading)
                    .frame(width: 130, height: 130)

                Text("\(Int((scan.coverageMap.solidFraction * 100).rounded())) % från flera håll")
                    .font(.caption2)
                Text("Gult = bara ett håll. Tomt = aldrig filmat.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.trailing, 16)
            .padding(.top, 8)
        }
    }

    private var scanningHint: some View {
        VStack(spacing: 8) {
            Text("Gå långsamt runt rummet. Kameran fotograferar samtidigt, så håll väggar och möbler väl belysta i bild.")
                .multilineTextAlignment(.center)

            // Står siffran kvar på noll efter några steg är scenrekonstruktionen
            // inte igång, och rummet blir lådor. Det är bättre att veta här än
            // vid bakningen.
            Label(scan.liveTriangleCount == 0
                    ? "Ingen yta ännu"
                    : "\(scan.liveTriangleCount) trianglar uppmätta",
                  systemImage: scan.liveTriangleCount == 0
                    ? "exclamationmark.triangle"
                    : "checkmark.circle")
                .foregroundStyle(scan.liveTriangleCount == 0 ? .orange : .green)

            Text(scan.sessionState)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
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
                // Utan trianglar blir rummet RoomPlans lådor. Det syns bäst här,
                // medan kunden fortfarande står kvar och kan skanna om.
                LabeledContent("Uppmätt yta",
                               value: scan.sceneMesh.isEmpty
                                   ? "saknas — rummet visas som lådor"
                                   : "\(scan.sceneMesh.triangleCount) trianglar")
            }

            coverageSection

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
        .task { await measureCoverage() }
    }

    /// Vad fotona täcker, medan kunden fortfarande kan göra något åt det.
    ///
    /// En yta som bara setts från ett håll ser bra ut från just det hållet och
    /// faller isär när man vrider sig i det färdiga rummet. Det går inte att
    /// laga i efterhand — därför står talet här och inte bara i rumsvyn.
    @ViewBuilder
    private var coverageSection: some View {
        if !scan.sceneMesh.isEmpty && !scan.keyframes.isEmpty {
            Section("Fotograferad yta") {
                if let coverage {
                    LabeledContent("Uppmätt från flera håll",
                                   value: percent(coverage.solidFraction))
                    LabeledContent("Bara från ett håll", value: percent(coverage.thinFraction))
                    LabeledContent("Inget foto ser ytan", value: percent(coverage.missingFraction))
                    if coverage.thinFraction + coverage.missingFraction >= 0.1 {
                        Text("Skanna om de delarna innan du lämnar rummet. Gå runt möblerna i stället för förbi dem — en yta som bara setts från ett håll går inte att återge från något annat.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                } else {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Mäter täckningen…")
                    }
                }
            }
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

    private func measureCoverage() async {
        guard coverage == nil, !scan.sceneMesh.isEmpty, !scan.keyframes.isEmpty else { return }
        let mesh = scan.sceneMesh
        let keyframes = scan.keyframes
        let folder = scan.photoDirectory
        coverage = await Task.detached(priority: .userInitiated) {
            let depth = DepthMaps(keyframes: keyframes, directory: folder)
            return SurfaceCoverage.measure(mesh: mesh, keyframes: keyframes, depth: depth.lookup)
        }.value
    }

    private func save(_ captured: CapturedRoom) {
        do {
            let saved = try store.save(captured,
                                       name: name.trimmingCharacters(in: .whitespaces),
                                       keyframes: scan.keyframes,
                                       photoDirectory: scan.photoDirectory,
                                       sceneMesh: scan.sceneMesh)
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
