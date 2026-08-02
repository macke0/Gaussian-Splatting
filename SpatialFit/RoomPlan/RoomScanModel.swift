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
        arSession.run(Self.configuration())
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        // Fotona hämtas ur samma session, utan att dess delegat tas över.
        recorder.start(session: arSession)
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
        // Måste läsas innan sessionen stoppas — sedan är anchors borta.
        sceneMesh = SceneMeshRecorder.snapshot(of: arSession)
        captureView.captureSession.stop()
    }

    /// Avbryt utan att efterbehandla.
    func cancel() {
        recorder.stop()
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
