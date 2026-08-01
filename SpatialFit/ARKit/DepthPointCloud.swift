//
//  DepthPointCloud.swift
//  SpatialFit
//
//  ARFrame → världspunkter. Enda stället som rör ARKits djupkarta.
//
//  Härlett ur PulsAr/ICA_ai:s `extrahera3DPunkter`, med tre ändringar för
//  mätning i stället för kartläggning:
//
//    1. `smoothedSceneDepth` föredras. Den temporala filtreringen sänker
//       bruset per punkt, vilket är precis vad planpassningen vill ha.
//       (För lokalisering vill man tvärtom ha råa värden utan eftersläpning.)
//    2. Intrinsics skalas ned till djupkartans upplösning i stället för att
//       djuppixlarna skalas upp till kamerabildens. Samma matematik, men
//       avrundningen sker inte mitt i projektionen.
//    3. Räckvidden begränsas hårt. LiDAR:ns brus växer ungefär kvadratiskt
//       med avståndet – en nisch mäts på en meter, inte på fem.
//

import ARKit
import Foundation
import simd

enum DepthPointCloud {

    /// Punkter närmare än så är inom sensorns döda zon.
    static let minimumRangeMeters: Float = 0.15
    /// Bortom detta är bruset för stort för att bidra till ett millimetermått.
    static let maximumRangeMeters: Float = 3.0

    /// Läs ut djupkartan som världskoordinater.
    ///
    /// - Parameters:
    ///   - frame: Bildrutan. Kräver att sessionen kör med `.smoothedSceneDepth`
    ///     eller `.sceneDepth` i `frameSemantics`.
    ///   - stride: Läs var n:te pixel. 1 ger hela kartan (~250k punkter,
    ///     för dyrt per bildruta); 4 ger ~16k vilket räcker gott när punkterna
    ///     ändå ackumuleras över flera rutor.
    ///   - minimumConfidence: ARKits konfidensnivå som lägsta krav.
    /// - Returns: Punkter i ARKits världskoordinatsystem, meter.
    static func samples(from frame: ARFrame,
                        stride: Int = 4,
                        minimumConfidence: ARConfidenceLevel = .medium) -> [DepthSample] {

        guard let depth = frame.smoothedSceneDepth ?? frame.sceneDepth else { return [] }
        let depthMap = depth.depthMap
        guard let confidenceMap = depth.confidenceMap else { return [] }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap),
              let confidenceBase = CVPixelBufferGetBaseAddress(confidenceMap) else { return [] }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let depthRowStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let confidenceRowStride = CVPixelBufferGetBytesPerRow(confidenceMap)

        // Intrinsics gäller kamerabildens upplösning – skala till djupkartans.
        let imageResolution = frame.camera.imageResolution
        let scaleX = Float(width) / Float(imageResolution.width)
        let scaleY = Float(height) / Float(imageResolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics[0][0] * scaleX
        let fy = intrinsics[1][1] * scaleY
        let cx = intrinsics[2][0] * scaleX
        let cy = intrinsics[2][1] * scaleY
        guard fx > 0, fy > 0 else { return [] }

        let worldFromCamera = frame.camera.transform
        let minimumRaw = UInt8(minimumConfidence.rawValue)

        var samples: [DepthSample] = []
        samples.reserveCapacity((width / stride) * (height / stride))

        let depthValues = depthBase.assumingMemoryBound(to: Float32.self)
        let confidenceValues = confidenceBase.assumingMemoryBound(to: UInt8.self)

        for row in Swift.stride(from: 0, to: height, by: stride) {
            for column in Swift.stride(from: 0, to: width, by: stride) {
                let confidence = confidenceValues[row * confidenceRowStride + column]
                guard confidence >= minimumRaw else { continue }

                let distance = depthValues[row * depthRowStride + column]
                guard distance >= minimumRangeMeters, distance <= maximumRangeMeters else { continue }

                // ARKits kamerarum: +X höger, +Y upp, +Z bakåt. Bildpixlar har
                // +v nedåt och djupet framåt, därför tecknen på y och z.
                let x = (Float(column) - cx) * distance / fx
                let y = -(Float(row) - cy) * distance / fy
                let z = -distance

                let world = worldFromCamera * SIMD4<Float>(x, y, z, 1)
                samples.append(DepthSample(position: SIMD3(world.x, world.y, world.z),
                                           confidence: Float(confidence) / 2))
            }
        }

        return samples
    }
}
