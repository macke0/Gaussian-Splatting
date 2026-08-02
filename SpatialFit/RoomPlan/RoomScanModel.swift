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

    override init() {
        if RoomCaptureSession.isSupported {
            captureView = RoomCaptureView(frame: .zero)
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
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
    }

    /// Avsluta skanningen och låt RoomPlan efterbehandla. Resultatet kommer i
    /// `captureView(didPresent:error:)`.
    func finish() {
        guard case .scanning = phase, let captureView else { return }
        phase = .processing
        captureView.captureSession.stop()
    }

    /// Avbryt utan att efterbehandla.
    func cancel() {
        captureView?.captureSession.stop(pauseARSession: true)
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
