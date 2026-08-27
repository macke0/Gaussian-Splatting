//
//  RoomScanModel.swift
//  SpatialFit
//
//  Skanningens tillstånd och RoomPlans delegatprotokoll, samlat på ett ställe
//  så att vyn bara har SwiftUI i sig.
//
//  Klassen äger `RoomCaptureView`. Den skapas aldrig på en enhet utan LiDAR –
//  `RoomCaptureSession.isSupported` avgör innan något instansieras, för annars
//  kraschar det i stället för att säga vad som är fel.
//

import Foundation
import Observation
import RoomPlan
import ARKit

@MainActor
@Observable
final class RoomScanModel: NSObject, RoomCaptureViewDelegate {

    enum Phase {
        case unsupported
        case scanning
        case processing
        /// Rummet i sin helhet plus de nischer tolkningen hittade. Rummet
        /// behövs för att kunna spara mesh:en, nischerna för att välja plats.
        case finished(CapturedRoom, [ScannedNiche])
        case failed(String)
    }

    private(set) var phase: Phase
    /// Vyn som ritar skanningen. `nil` när enheten saknar LiDAR.
    let captureView: RoomCaptureView?

    /// Fotona som ska måla rummet. De ligger i en temporär mapp tills rummet
    /// sparas och får ett id att lägga dem under.
    let photoDirectory: URL
    @ObservationIgnored private let recorder: KeyframeRecorder

    /// Sessionen ägs av oss, inte av RoomPlan. Det är enda sättet att slå på
    /// scenrekonstruktion — RoomPlans egen konfiguration har den inte, och utan
    /// den finns inga `ARMeshAnchor` att bygga rummets verkliga form ur.
    @ObservationIgnored private let arSession = ARSession()

    var keyframes: [Keyframe] { recorder.keyframes }

    /// Den täta ytan ARKit rekonstruerade. Fylls när skanningen avslutas —
    /// dessförinnan växer den fortfarande.
    private(set) var sceneMesh = SceneMesh()

    /// Trianglar rekonstruktionen byggt hittills. Räknas medan skanningen pågår,
    /// för står den kvar på noll är scenrekonstruktionen inte igång — och det
    /// ska synas medan kunden fortfarande står i rummet, inte när rummet ska
    /// målas en timme senare. Bara antalet läses, ingen geometri kopieras.
    private(set) var liveTriangleCount = 0
    @ObservationIgnored private var meshWatch: Timer?

    /// Rummet uppifrån, färgat efter hur brett varje del setts. Ritas medan
    /// kunden filmar — det är enda tillfället kartan kan ändra på något.
    private(set) var coverageMap = LiveCoverage.Map.empty
    /// Var kameran är och vart den pekar, så att kartan går att läsa som en
    /// karta. Utan pricken vet man inte vilket håll man tittar åt på den.
    private(set) var devicePosition = SIMD2<Float>.zero
    private(set) var deviceHeading = SIMD2<Float>(0, -1)

    /// Vad sessionen faktiskt kör, inte vad vi bad om. Skillnaden är hela frågan:
    /// står rekonstruktionen på `av` har någon skrivit över vår konfiguration,
    /// står den på `mesh` utan att trianglarna växer är det avläsningen av
    /// anchors som är fel. Utan enhet i handen går det inte att gissa fram.
    private(set) var sessionState = ""
    @ObservationIgnored private var hasRetriedConfiguration = false

    override init() {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "scan-\(UUID().uuidString)")
        photoDirectory = folder
        recorder = KeyframeRecorder(directory: folder)

        if RoomCaptureSession.isSupported {
            captureView = RoomCaptureView(frame: .zero, arSession: arSession)
            phase = .scanning
        } else {
            captureView = nil
            phase = .unsupported
        }
        super.init()
        captureView?.delegate = self
    }

    /// `RoomCaptureViewDelegate` ärver `NSCoding`. Modellen serialiseras aldrig
    /// – kraven finns bara för att uppfylla protokollet.
    nonisolated required init?(coder: NSCoder) { nil }
    nonisolated func encode(with coder: NSCoder) {}

    func start() {
        guard let captureView else { return }
        phase = .scanning

        // Ordningen spelar mindre roll än den ser ut att göra: RoomPlan kör om
        // sessionen med sin egen konfiguration även efter det här. Det som
        // räddar scenrekonstruktionen är omkörningen i `pollSession()`.
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        arSession.run(Self.configuration())

        // Fotona hämtas ur samma session, utan att dess delegat tas över.
        recorder.start(session: arSession)

        // Samma skäl här: sessionens delegat tillhör RoomPlan, så anchors
        // pollas i stället för att prenumereras på.
        meshWatch?.invalidate()
        // En halv sekund: kartan ändrar sig långsamt, men pricken som visar var
        // man står ska följa med när man går, annars går den inte att navigera
        // efter. Avläsningen är en genomgång av anchors och kostar ingenting.
        meshWatch = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollSession() }
        }
    }

    private func pollSession() {
        let frame = arSession.currentFrame
        let anchors = frame?.anchors ?? []
        let meshes = anchors.compactMap { $0 as? ARMeshAnchor }
        liveTriangleCount = meshes.reduce(0) { $0 + $1.geometry.faces.count }

        coverageMap = recorder.coverage.map()
        if let pose = frame?.camera.transform {
            devicePosition = SIMD2(pose.columns.3.x, pose.columns.3.z)
            // Kamerans blick är dess egna minus-Z. Uppifrån räknas bara planet,
            // och pekar den rakt ned i golvet finns inget håll att rita.
            let heading = SIMD2(-pose.columns.2.x, -pose.columns.2.z)
            if simd_length(heading) > 0.01 { deviceHeading = simd_normalize(heading) }
        }

        let running = (arSession.configuration as? ARWorldTrackingConfiguration)?.sceneReconstruction
        sessionState = "rekonstruktion \(Self.describe(running))"
            + " · \(anchors.count) anchors, \(meshes.count) mesh"
            + " · djup \(frame?.sceneDepth == nil ? "nej" : "ja")"

        // Det här är vad som faktiskt får ytan att finnas. RoomPlan kör om den
        // delade sessionen med sin egen konfiguration en stund EFTER att
        // `captureSession.run` returnerat, så vår scenrekonstruktion hinner bli
        // överskriven hur vi än lägger anropen i `start()`. Att sätta tillbaka
        // den när vi ser att den är borta är enda vägen som fungerar på enhet.
        if !hasRetriedConfiguration, running?.contains(.mesh) != true {
            hasRetriedConfiguration = true
            arSession.run(Self.configuration())
        }
    }

    private static func describe(_ mode: ARConfiguration.SceneReconstruction?) -> String {
        guard let mode else { return "ingen konfiguration" }
        if mode.contains(.meshWithClassification) { return "mesh+klassificering" }
        if mode.contains(.mesh) { return "mesh" }
        return ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
            ? "av" : "stöds inte av enheten"
    }

    /// Det RoomPlan behöver — djup och släta djupkartor — plus scenrekonstruktion.
    /// Utan `.mesh` blir rummet RoomPlans lådor, för då finns ingen tät yta.
    private static func configuration() -> ARWorldTrackingConfiguration {
        let configuration = ARWorldTrackingConfiguration()
        configuration.frameSemantics.insert(.sceneDepth)
        configuration.frameSemantics.insert(.smoothedSceneDepth)
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.planeDetection = [.horizontal, .vertical]
        return configuration
    }

    /// Avsluta skanningen och låt RoomPlan efterbehandla. Resultatet kommer i
    /// `captureView(didPresent:error:)`.
    func finish() {
        guard case .scanning = phase, let captureView else { return }
        phase = .processing
        recorder.stop()
        meshWatch?.invalidate()
        meshWatch = nil
        // Måste läsas innan sessionen stoppas — sedan är anchors borta.
        sceneMesh = SceneMeshRecorder.snapshot(of: arSession)
        captureView.captureSession.stop()
    }

    /// Avbryt utan att efterbehandla.
    func cancel() {
        recorder.stop()
        meshWatch?.invalidate()
        meshWatch = nil
        captureView?.captureSession.stop(pauseARSession: true)
        try? FileManager.default.removeItem(at: photoDirectory)
    }

    // MARK: - RoomCaptureViewDelegate

    nonisolated func captureView(shouldPresent roomDataForProcessing: CapturedRoomData,
                                 error: Error?) -> Bool {
        if let error {
            Task { @MainActor in phase = .failed(error.localizedDescription) }
            return false
        }
        return true
    }

    nonisolated func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        Task { @MainActor in
            if let error {
                phase = .failed(error.localizedDescription)
            } else {
                let niches = NicheFinder.niches(in: CapturedRoomReader.elements(from: processedResult))
                phase = .finished(processedResult, niches)
            }
        }
    }
}
