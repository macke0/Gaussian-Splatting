//
//  SurfaceCoverage.swift
//  SpatialFit
//
//  Vilka delar av rummet har skanningen faktiskt fotograferat, och vad är kvar?
//
//  Mätt på det bakade rummet: när modellen ser fotorealistisk ut från ett håll
//  men faller isär när man vrider sig, tittar den trasiga riktningen på yta som
//  INGET foto ser. Varje vy vars yta hade noll foton per punkt och under 30°
//  vinkelspann var trasig; varje vy med många foton och brett spann var hel.
//  Det är alltså inte träningen som brister utan insamlingen, och det går inte
//  att laga i efterhand — en yta ingen fotograferat finns inte att rekonstruera.
//
//  Därför den här mätningen: den svarar medan kunden fortfarande står i rummet
//  och kan gå tillbaka. Två tal per hörn räcker för att avgöra saken:
//
//    ANTAL    hur många foton som ser hörnet. Noll är ett hål.
//    SPANN    den största vinkeln mellan två av de fotona.
//
//  Spannet är det som avgör, inte antalet. Tio foton tagna i följd från nästan
//  samma plats säger ingenting mer än ett — ytan är då MÅLAD, inte uppmätt, och
//  faller isär så fort betraktaren rör sig utanför konen. Tumreglerna kommer ur
//  fotogrammetrin: under 10° är djupet en gissning, över 30° är ytan bestämd.
//
//  Ren simd och Foundation. Därför testbar utan enhet.
//

import Foundation
import simd

enum SurfaceCoverage {

    /// Hur väl en punkt på ytan är fotograferad.
    ///
    /// Ordningen är avsiktlig: `rawValue` växer med hur illa det står till, så
    /// en triangels nivå är den största av dess tre hörns. En triangel med ett
    /// ofotograferat hörn ska visas som ett hål, inte som halvt täckt.
    enum Level: UInt32, Sendable, CaseIterable {
        /// Sett från minst två håll med brett vinkelspann. Går att rekonstruera.
        case solid = 0
        /// Sett, men inom en smal kon. Ser bra ut från just det hållet.
        case thin = 1
        /// Inget foto ser ytan. Ingen efterbehandling kan laga det.
        case missing = 2

        /// Färgen nivån visas i. Ligger här och inte i ritlagret för att både
        /// den ritade mesh:en och kartan under skanningen ska säga samma sak —
        /// gult ska betyda gult på båda ställena.
        var tint: (red: Double, green: Double, blue: Double) {
            switch self {
            case .solid: (0.20, 0.72, 0.35)
            case .thin: (0.95, 0.72, 0.15)
            case .missing: (0.90, 0.22, 0.22)
            }
        }
    }

    /// Vinkelspannet en yta måste ha setts inom för att räknas som bestämd.
    static let minimumSpreadDegrees: Float = 30

    struct Report: Sendable {
        /// En nivå per hörn i mesh:en.
        let levels: [Level]
        /// En nivå per triangel — den sämsta av dess tre hörns.
        let faceLevels: [UInt32]

        var solidFraction: Double { fraction(of: .solid) }
        var thinFraction: Double { fraction(of: .thin) }
        var missingFraction: Double { fraction(of: .missing) }

        private func fraction(of level: Level) -> Double {
            guard !levels.isEmpty else { return 0 }
            let matching = levels.reduce(into: 0) { total, item in
                if item == level { total += 1 }
            }
            return Double(matching) / Double(levels.count)
        }
    }

    /// Mäter täckningen för varje hörn i mesh:en.
    ///
    /// - Parameter depth: skanningens djupkartor. De slänger ytor som låg bakom
    ///   något annat: väggen bakom en soffa projiceras in i bildrutan precis som
    ///   soffan gör, och utan testet skulle mätningen påstå att det är
    ///   fotograferat bakom möblerna. Saknas djupet för en bild räknas den ändå
    ///   — samma val som `ViewSelection`, och av samma skäl: en gammal skanning
    ///   utan djupkartor ska inte visas som om ingenting alls vore fotograferat.
    static func measure(mesh: SceneMesh,
                        keyframes: [Keyframe],
                        depth: ViewSelection.DepthLookup) -> Report {
        guard !mesh.isEmpty else {
            return Report(levels: [], faceLevels: [])
        }

        let normals = mesh.vertexNormals()
        var levels = [Level](repeating: .missing, count: mesh.positions.count)

        // Ett par hundra tusen hörn mot ett par hundra foton är tiotals miljoner
        // projektioner. Uppdelat på kärnorna tar det bråkdelen av en sekund, och
        // hörnen är oberoende av varandra så det finns inget att synkronisera.
        levels.withUnsafeMutableBufferPointer { output in
            let chunk = 4096
            let chunks = (mesh.positions.count + chunk - 1) / chunk
            DispatchQueue.concurrentPerform(iterations: chunks) { block in
                let start = block * chunk
                let end = min(start + chunk, mesh.positions.count)
                for vertex in start..<end {
                    output[vertex] = level(of: mesh.positions[vertex],
                                           normal: normals[vertex],
                                           keyframes: keyframes,
                                           depth: depth)
                }
            }
        }

        var faceLevels = [UInt32]()
        faceLevels.reserveCapacity(mesh.triangleCount)
        for triangle in stride(from: 0, to: mesh.indices.count - 2, by: 3) {
            let worst = max(levels[Int(mesh.indices[triangle])].rawValue,
                            max(levels[Int(mesh.indices[triangle + 1])].rawValue,
                                levels[Int(mesh.indices[triangle + 2])].rawValue))
            faceLevels.append(worst)
        }

        return Report(levels: levels, faceLevels: faceLevels)
    }

    // MARK: - Ett hörn

    /// Villkoren är med flit desamma som `ViewSelection.score` ställer på en
    /// triangel: håller de inte går ytan inte att måla ur bilden, och då är den
    /// inte fotograferad i någon mening som hjälper kunden.
    private static func level(of point: SIMD3<Float>,
                              normal: SIMD3<Float>,
                              keyframes: [Keyframe],
                              depth: ViewSelection.DepthLookup) -> Level {
        var count = 0
        // Riktningarna summeras i stället för att sparas. Se `spread`.
        var sum = SIMD3<Float>.zero

        for keyframe in keyframes {
            guard let projection = keyframe.project(point) else { continue }

            let toCamera = keyframe.position - point
            let distance = simd_length(toCamera)
            guard distance > 0.05, distance < ViewSelection.maximumDistanceM else { continue }

            // Mesh-normalen kan peka åt endera hållet; det som räknas är att
            // ytan setts någotsånär rakt på.
            let direction = toCamera / distance
            guard abs(simd_dot(normal, direction)) >= ViewSelection.minimumFacing else { continue }

            // Låg något annat framför? Då såg bilden inte den här ytan.
            if let measured = depth(keyframe, keyframe.depthIndex(for: projection.pixel)),
               measured > 0,
               measured < projection.depth - ViewSelection.occlusionToleranceM {
                continue
            }

            count += 1
            sum += direction
        }

        guard count > 0 else { return .missing }
        return spread(count: count, sum: sum) >= minimumSpreadDegrees ? .solid : .thin
    }

    /// Vinkelspannet mellan de foton som ser punkten, i grader.
    ///
    /// Den exakta definitionen — största vinkeln mellan två av riktningarna —
    /// kostar en jämförelse per par, och med hundratals foton per hörn gånger
    /// hundratusentals hörn går det inte. I stället används resultantens längd:
    /// för TVÅ riktningar ger `2·acos(|Σd| / n)` exakt vinkeln mellan dem, och
    /// för fler underskattar den något. Felet pekar åt rätt håll — mätningen
    /// varnar hellre för tunn täckning än påstår att den är god.
    static func spread(count: Int, sum: SIMD3<Float>) -> Float {
        guard count > 1 else { return 0 }
        let resultant = simd_length(sum) / Float(count)
        return 2 * acos(min(max(resultant, 0), 1)) * 180 / .pi
    }
}
