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
//  Den som skannar går medan bilden tas, så var tredje bildruta är rörelseoskarp.
//  Mätt på ett riktigt rum skilde det fyra gånger mellan den skarpaste och den
//  suddigaste bilden, och bakningen blandar ihop dem. Därför vägs skärpan innan
//  bilden sparas: är den mycket sämre än de tidigare väntar vi några bildrutor
//  på en bättre.
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
    /// Bredd i pixlar på den sparade bilden. Ska följa atlasens upplösning:
    /// vid 1536 px täcker en fotopixel ungefär 1,8 mm av väggen, vilket är vad
    /// en texel i en atlas på 4096 också gör. Höjs bara den ena blir den grövre
    /// av dem taket ändå, och den finare bara dyrare.
    private let targetWidth: CGFloat = 1536

    /// Hur mycket sämre än de tidigare bilderna en bild får vara och ändå
    /// sparas. Vid 0.75 släpps normalt brus igenom men inte en tydlig sudd.
    private let sharpnessFloor = 0.75
    /// Så många bildrutor får letandet efter en skarpare bild ta innan vi
    /// nöjer oss. 5 × 0.2 s ≈ en sekund; längre och kunden hinner vända bort
    /// kameran, och då blir ytan omålad i stället för suddig. Det är sämre.
    private let patience = 5

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var timer: Timer?
    private weak var session: ARSession?
    /// Skärpan hos de bilder som sparats, i den ordning de togs. Jämförelsen
    /// måste vara relativ — ett rum med vita väggar har låg kontrast överallt.
    private var recordedSharpness: [Double] = []
    private var skippedFrames = 0

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
              hasMovedEnough(to: frame.camera.transform),
              let rendered = render(frame) else { return }

        guard isSharpEnough(rendered.sharpness) || skippedFrames >= patience else {
            skippedFrames += 1
            return
        }
        skippedFrames = 0
        store(rendered, from: frame)
    }

    /// Sant om bilden håller måttet mot dem som redan sparats. Den första har
    /// inget att jämföras med och släpps alltid igenom.
    private func isSharpEnough(_ value: Double) -> Bool {
        guard !recordedSharpness.isEmpty else { return true }
        let sorted = recordedSharpness.sorted()
        let median = sorted[sorted.count / 2]
        return value >= median * sharpnessFloor
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

    /// En färdig bild som ännu inte bestämts vara värd att spara.
    private struct Rendered {
        let jpeg: Data
        let scale: Float
        let size: CGSize
        let sharpness: Double
    }

    private func render(_ frame: ARFrame) -> Rendered? {
        let source = CIImage(cvPixelBuffer: frame.capturedImage)
        let scale = targetWidth / source.extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let image = context.createCGImage(scaled, from: scaled.extent),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }

        return Rendered(jpeg: jpeg,
                        scale: Float(scale),
                        size: scaled.extent.size,
                        sharpness: sharpness(of: image))
    }

    private func store(_ rendered: Rendered, from frame: ARFrame) {
        let id = keyframes.count
        let imageURL = directory.appending(path: "kf\(id).jpg")
        guard (try? rendered.jpeg.write(to: imageURL)) != nil else { return }

        let depthSize = writeDepth(frame, id: id)
        recordedSharpness.append(rendered.sharpness)

        keyframes.append(Keyframe(id: id,
                                  worldFromCamera: frame.camera.transform,
                                  intrinsics: scaledIntrinsics(frame.camera.intrinsics, by: rendered.scale),
                                  imageSize: SIMD2(Float(rendered.size.width), Float(rendered.size.height)),
                                  depthSize: depthSize))
    }

    /// Medelskillnaden mellan grannpixlar i en gråskalekopia. Rörelseoskärpa
    /// jämnar ut den. Samma mått som servern viktar bilderna med, så en bild
    /// som släpps igenom här väger också tungt vid bakningen.
    ///
    /// Kopian är nedskalad — full upplösning kostar mer än den ger, oskärpan
    /// från ett steg i sidled är flera pixlar bred.
    private func sharpness(of image: CGImage) -> Double {
        let width = 384
        let height = max(2, width * image.height / image.width)
        guard let grey = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = grey.data else { return 0 }
        grey.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let stride = grey.bytesPerRow
        let pixels = base.bindMemory(to: UInt8.self, capacity: stride * height)
        var total = 0
        for row in 1..<height {
            let line = row * stride
            for column in 1..<width {
                let value = Int(pixels[line + column])
                total += abs(value - Int(pixels[line + column - 1]))
                total += abs(value - Int(pixels[line - stride + column]))
            }
        }
        return Double(total) / Double(2 * (height - 1) * (width - 1))
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
