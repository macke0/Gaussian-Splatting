//
//  KeyframeRecorder.swift
//  SpatialFit
//
//  Sparar kamerabilder med känd placering medan RoomPlan skannar. RoomPlan
//  exponerar sin `arSession`, så bilderna kan hämtas utan att störa skanningen
//  — sessionens delegat lämnas orörd och bildrutorna pollas i stället.
//
//  En bildruta blir en keyframe först när kameran flyttat eller vridit sig
//  tillräckligt. Annars fylls disken med fyrtio bilder av samma vägg.
//

import Foundation
import ARKit
import CoreImage
import UIKit

@MainActor
final class KeyframeRecorder {

    private(set) var keyframes: [Keyframe] = []

    private let directory: URL
    private let maximumCount: Int
    /// Bredd i pixlar på den sparade bilden. Full sensorupplösning ger inte
    /// bättre textur än vad mesh:ens triangelstorlek klarar av att visa.
    private let targetWidth: CGFloat = 768

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var timer: Timer?
    private weak var session: ARSession?

    /// - Parameter maximumCount: fotobudgeten. Tar den slut mitt i skanningen
    ///   saknar resten av rummet bild, och ytorna målas från fel håll.
    init(directory: URL, maximumCount: Int = 40) {
        self.directory = directory
        self.maximumCount = maximumCount
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(session: ARSession) {
        self.session = session
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session = nil
    }

    // MARK: - Insamling

    private func tick() {
        guard keyframes.count < maximumCount,
              let frame = session?.currentFrame,
              hasMovedEnough(to: frame.camera.transform) else { return }
        capture(frame)
    }

    /// 30 cm eller 20° från den senaste bilden. Under det ser man i praktiken
    /// samma yta från samma håll.
    private func hasMovedEnough(to pose: simd_float4x4) -> Bool {
        guard let previous = keyframes.last?.worldFromCamera else { return true }

        let movement = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                                     SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z))
        if movement > 0.30 { return true }

        let forward = SIMD3<Float>(-pose.columns.2.x, -pose.columns.2.y, -pose.columns.2.z)
        let previousForward = SIMD3<Float>(-previous.columns.2.x, -previous.columns.2.y, -previous.columns.2.z)
        return simd_dot(forward, previousForward) < cos(20 * .pi / 180)
    }

    private func capture(_ frame: ARFrame) {
        let source = CIImage(cvPixelBuffer: frame.capturedImage)
        let scale = targetWidth / source.extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let image = context.createCGImage(scaled, from: scaled.extent),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return }

        let id = keyframes.count
        let imageURL = directory.appending(path: "kf\(id).jpg")
        guard (try? jpeg.write(to: imageURL)) != nil else { return }

        let depthSize = writeDepth(frame, id: id)

        keyframes.append(Keyframe(id: id,
                                  worldFromCamera: frame.camera.transform,
                                  intrinsics: scaledIntrinsics(frame.camera.intrinsics, by: Float(scale)),
                                  imageSize: SIMD2(Float(scaled.extent.width), Float(scaled.extent.height)),
                                  depthSize: depthSize))
    }

    /// Brännvidd och bildcentrum skalas med bilden, annars projiceras punkterna
    /// mot en upplösning som inte längre finns.
    private func scaledIntrinsics(_ intrinsics: simd_float3x3, by scale: Float) -> simd_float3x3 {
        var scaled = intrinsics
        scaled.columns.0.x *= scale
        scaled.columns.1.y *= scale
        scaled.columns.2.x *= scale
        scaled.columns.2.y *= scale
        return scaled
    }

    /// LiDAR-djupet, rått Float32. Utan det går ocklusion inte att avgöra och
    /// väggen bakom en spis målas ut över spisen.
    private func writeDepth(_ frame: ARFrame, id: Int) -> SIMD2<Int32> {
        guard let map = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap else {
            return SIMD2(0, 0)
        }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return SIMD2(0, 0) }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

        var data = Data(capacity: width * height * MemoryLayout<Float>.size)
        for row in 0..<height {
            data.append(Data(bytes: base.advanced(by: row * bytesPerRow),
                             count: width * MemoryLayout<Float>.size))
        }

        guard (try? data.write(to: directory.appending(path: "kf\(id).depth"))) != nil else {
            return SIMD2(0, 0)
        }
        return SIMD2(Int32(width), Int32(height))
    }
}
