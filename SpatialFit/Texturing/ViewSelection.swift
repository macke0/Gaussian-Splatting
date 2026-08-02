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

    /// Minsta `cos(vinkel)` mellan ytans normal och siktlinjen. 0.35 ≈ 70°.
    /// Snävare än så blir texturen märkbart utsmetad.
    static let minimumFacing: Float = 0.35

    /// Längre bort än så upptar ytan för få pixlar för att måla med.
    static let maximumDistanceM: Float = 4.5

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
        guard distance > 0.05, distance < maximumDistanceM else { return nil }

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

    // MARK: - Uppdelning

    /// Delar trianglar tills ingen kant är längre än `maximumEdge`.
    ///
    /// Kravet på att alla tre hörnen ska synas i samma bild är hårt mot stora
    /// trianglar: en vägg som RoomPlan lämnat som två trianglar ryms inte i ett
    /// foto taget en och en halv meter bort, och blir därför aldrig målad.
    /// Mindre bitar får plats — och kan dessutom följa rummet närmare.
    /// - Parameter budget: tak för antalet bitar. Nås det får resten av
    ///   trianglarna vara som de är — hellre grovt målade än slut på minne.
    static func subdivided(_ triangles: [Triangle],
                           maximumEdge: Float,
                           maximumDepth: Int = 4,
                           budget: Int = 400_000) -> [Triangle] {
        var result: [Triangle] = []
        result.reserveCapacity(triangles.count)
        for (index, triangle) in triangles.enumerated() {
            guard result.count + (triangles.count - index) < budget else {
                result.append(contentsOf: triangles[index...])
                break
            }
            split(triangle, maximumEdge: maximumEdge, depth: maximumDepth, into: &result)
        }
        return result
    }

    /// Delar på kantmitterna. Två trianglar som delar en kant delar den på
    /// samma punkt, så ytan förblir tät.
    private static func split(_ triangle: Triangle,
                              maximumEdge: Float,
                              depth: Int,
                              into result: inout [Triangle]) {
        let longest = max(simd_distance(triangle.a, triangle.b),
                          simd_distance(triangle.b, triangle.c),
                          simd_distance(triangle.c, triangle.a))
        guard depth > 0, longest > maximumEdge else {
            result.append(triangle)
            return
        }

        let ab = (triangle.a + triangle.b) / 2
        let bc = (triangle.b + triangle.c) / 2
        let ca = (triangle.c + triangle.a) / 2

        for piece in [Triangle(triangle.a, ab, ca),
                      Triangle(ab, triangle.b, bc),
                      Triangle(ca, bc, triangle.c),
                      Triangle(ab, bc, ca)] {
            split(piece, maximumEdge: maximumEdge, depth: depth - 1, into: &result)
        }
    }

    // MARK: - Sammanhängande val

    /// Hur mycket sämre en grannes bild får vara innan sammanhanget väger
    /// tyngre. Ett foto som ser ytan halvt så bra men målar hela väggen är
    /// bättre än två foton som möts mitt på den.
    static let coherenceTolerance: Float = 0.45

    /// Väljer bild för varje triangel och jämnar sedan ut valet mellan grannar.
    ///
    /// Poängen `facing / distance` växlar snabbt över en yta, så det bästa
    /// fotot skiftar från triangel till triangel. Var för sig är valen riktiga,
    /// men resultatet blir ett lapptäcke där varje lapp har sin egen exponering
    /// och sin egen lilla feljustering. Utjämningen låter stora sammanhängande
    /// områden dela foto, vilket är vad ögat läser som ett rum.
    ///
    /// - Returns: en keyframe-id per triangel, `nil` där ingen bild dög.
    static func assign(triangles: [Triangle],
                       keyframes: [Keyframe],
                       depth: DepthLookup,
                       passes: Int = 4) -> [Int?] {
        var labels = triangles.map { best(for: $0, among: keyframes, depth: depth)?.id }
        guard passes > 0, !labels.isEmpty else { return labels }

        let byID = Dictionary(keyframes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let neighbours = adjacency(of: triangles)

        for _ in 0..<passes {
            var changed = false
            // Uppdateringen sker på plats. Räknade man i stället fram alla nya
            // val ur de gamla skulle två grannar kunna byta med varandra om och
            // om igen utan att någonsin mötas.
            for index in triangles.indices {
                guard let current = labels[index],
                      let normal = triangles[index].normal,
                      let candidate = majority(around: index, in: neighbours, labels: labels),
                      candidate != current,
                      let alternative = byID[candidate],
                      let own = byID[current] else { continue }

                guard let ownScore = score(triangle: triangles[index], normal: normal,
                                           keyframe: own, depth: depth),
                      let candidateScore = score(triangle: triangles[index], normal: normal,
                                                 keyframe: alternative, depth: depth),
                      candidateScore >= ownScore * coherenceTolerance else { continue }
                labels[index] = candidate
                changed = true
            }
            if !changed { break }
        }
        return labels
    }

    /// Den bild fler än hälften av grannarna använder, om en sådan finns.
    /// Står två bilder lika får triangeln behålla sitt eget val — kanten mellan
    /// två foton måste ju gå någonstans.
    private static func majority(around index: Int,
                                 in neighbours: [[Int]],
                                 labels: [Int?]) -> Int? {
        var counts: [Int: Int] = [:]
        var total = 0
        for neighbour in neighbours[index] {
            guard let label = labels[neighbour] else { continue }
            counts[label, default: 0] += 1
            total += 1
        }
        guard let winner = counts.max(by: { $0.value < $1.value }),
              winner.value * 2 > total else { return nil }
        return winner.key
    }

    /// Trianglarna kommer utan delade index — varje hörn står för sig självt.
    /// Grannskapet byggs därför på hörnens läge, avrundat till millimeter så
    /// att flyttalsbrus inte river isär en kant som geometriskt är delad.
    private static func adjacency(of triangles: [Triangle]) -> [[Int]] {
        var byEdge: [Edge: [Int]] = [:]
        byEdge.reserveCapacity(triangles.count * 3)

        for (index, triangle) in triangles.enumerated() {
            let corners = [key(triangle.a), key(triangle.b), key(triangle.c)]
            for corner in 0..<3 {
                byEdge[Edge(corners[corner], corners[(corner + 1) % 3]), default: []].append(index)
            }
        }

        var result = [[Int]](repeating: [], count: triangles.count)
        for (_, sharing) in byEdge where sharing.count > 1 {
            for index in sharing {
                result[index].append(contentsOf: sharing.lazy.filter { $0 != index })
            }
        }
        return result
    }

    private struct Edge: Hashable {
        let low: SIMD3<Int32>
        let high: SIMD3<Int32>

        /// Kanten är oriktad, så hörnen sorteras innan de får bli nyckel.
        init(_ first: SIMD3<Int32>, _ second: SIMD3<Int32>) {
            let ordered = (first.x, first.y, first.z) <= (second.x, second.y, second.z)
            low = ordered ? first : second
            high = ordered ? second : first
        }
    }

    private static func key(_ point: SIMD3<Float>) -> SIMD3<Int32> {
        SIMD3(Int32((point.x * 1000).rounded()),
              Int32((point.y * 1000).rounded()),
              Int32((point.z * 1000).rounded()))
    }
}
