//
//  ViewSelection.swift
//  SpatialFit
//
//  Vilken kamerabild ska måla en given triangel?
//
//  Tre krav måste vara uppfyllda innan en bild ens är en kandidat:
//
//    1. Alla tre hörnen syns i bilden. Räcker det inte till hela triangeln
//       sträcks texturen ut över kanten och rummet blir randigt.
//    2. Ytan är vänd mot kameran. En vägg fotograferad snett bakifrån ger
//       utsmetade pixlar.
//    3. Ytan låg faktiskt främst. LiDAR-djupet avgör — utan det testet målas
//       väggen bakom en spis rakt ut över spisen.
//
//  Bland kandidaterna vinner den som ser ytan rakt på och nära.
//
//  Ren simd, ingen ARKit eller RealityKit. Därför testbar utan enhet.
//

import Foundation
import simd

enum ViewSelection {

    struct Triangle: Equatable, Sendable {
        let a: SIMD3<Float>
        let b: SIMD3<Float>
        let c: SIMD3<Float>

        init(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            self.a = a
            self.b = b
            self.c = c
        }

        var centroid: SIMD3<Float> { (a + b + c) / 3 }

        /// `nil` för degenererade trianglar, som saknar riktning att bedöma.
        var normal: SIMD3<Float>? {
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            return length > 1e-9 ? cross / length : nil
        }
    }

    /// Uppmätt avstånd i en keyframes djupkarta, eller `nil` om djup saknas.
    typealias DepthLookup = @Sendable (Keyframe, Int) -> Float?

    /// Hur mycket närmare den uppmätta ytan får ligga innan triangeln räknas
    /// som skymd. Marginalen täcker LiDAR-brus och mesh:ens egen utjämning.
    static let occlusionToleranceM: Float = 0.12

    /// Minsta `cos(vinkel)` mellan ytans normal och siktlinjen. 0.2 ≈ 78°.
    static let minimumFacing: Float = 0.2

    static func best(for triangle: Triangle,
                     among keyframes: [Keyframe],
                     depth: DepthLookup) -> Keyframe? {
        guard let normal = triangle.normal else { return nil }

        var winner: Keyframe?
        var bestScore: Float = 0

        for keyframe in keyframes {
            guard let score = score(triangle: triangle,
                                    normal: normal,
                                    keyframe: keyframe,
                                    depth: depth),
                  score > bestScore else { continue }
            bestScore = score
            winner = keyframe
        }
        return winner
    }

    /// `nil` när bilden inte duger. Annars ett värde där större är bättre.
    static func score(triangle: Triangle,
                      normal: SIMD3<Float>,
                      keyframe: Keyframe,
                      depth: DepthLookup) -> Float? {
        guard keyframe.project(triangle.a) != nil,
              keyframe.project(triangle.b) != nil,
              keyframe.project(triangle.c) != nil,
              let middle = keyframe.project(triangle.centroid) else { return nil }

        let toCamera = keyframe.position - triangle.centroid
        let distance = simd_length(toCamera)
        guard distance > 0.05 else { return nil }

        // Mesh-normalen kan peka åt endera hållet; det som räknas är att ytan
        // ses någotsånär rakt på.
        let facing = abs(simd_dot(normal, toCamera / distance))
        guard facing >= minimumFacing else { return nil }

        if let measured = depth(keyframe, keyframe.depthIndex(for: middle.pixel)),
           measured > 0,
           measured < middle.depth - occlusionToleranceM {
            return nil
        }

        return facing / distance
    }
}
