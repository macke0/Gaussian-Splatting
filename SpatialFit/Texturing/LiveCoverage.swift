//
//  LiveCoverage.swift
//  SpatialFit
//
//  Täckningen medan man filmar, inte efteråt.
//
//  `SurfaceCoverage` mäter mot en färdig mesh och en färdig fotolista. Det går
//  först när skanningen är slut, och då står kunden ofta redan i bilen. Den här
//  gör samma bedömning löpande, och kan det för att den inte behöver någon mesh:
//  varje foto kommer med en LiDAR-djupkarta, och veckas den ut i världen är
//  punkterna man får VAD KAMERAN FAKTISKT SÅG. Ocklusionen är gratis på köpet —
//  djupet stannar vid soffan, alltså hamnar ingen punkt i väggen bakom den.
//
//  Rummet delas i kuber. Varje kub minns hur många djuppunkter som landat i den
//  och summan av riktningarna de sågs från; av de två räknas samma vinkelspann
//  som `SurfaceCoverage` använder. Därför växer minnet med rummets yta och inte
//  med antalet foton, och kartan kan ritas om varje sekund utan att kosta något.
//
//  Det den INTE kan säga är vad som saknas helt. En yta ingen riktat kameran mot
//  har inga punkter, och en kub som aldrig fyllts går inte att skilja från luft.
//  Rött hör därför hemma i efterhandsmätningen, som har mesh:en att jämföra mot.
//  Här finns grönt och gult — och tomrummet, som är minst lika talande.
//
//  Ren simd och Foundation. Därför testbar utan enhet.
//

import Foundation
import simd

struct LiveCoverage: Sendable {

    /// Kubens sida i meter. 20 cm är grovt nog att en handfull djuppunkter
    /// hamnar i samma kub — annars blir varje kub sedd från exakt en riktning
    /// och allt gult — och fint nog att en bordsskiva blir flera rutor.
    static let cellSizeM: Float = 0.2

    /// Så många djuppunkter per foto vecklas ut. Djupkartan har 49 152; att ta
    /// alla vore slöseri, för grannpixlar landar ändå i samma kub.
    static let samplesPerFrame = 600

    /// Punkter närmare än så är oftast en hand eller kamerans eget brus, och
    /// längre bort än så är LiDAR-avståndet för osäkert för att peka ut en kub.
    static let minimumDistanceM: Float = 0.3
    static let maximumDistanceM: Float = 5.0

    private struct Sighting {
        var count: Int32 = 0
        var sum: SIMD3<Float> = .zero
    }

    private var cells: [SIMD3<Int32>: Sighting] = [:]

    var isEmpty: Bool { cells.isEmpty }

    // MARK: - Insamling

    /// Lägger till vad ett foto såg.
    ///
    /// - Parameter depth: djupkartan rå, radvis, `keyframe.depthSize` stor.
    ///
    /// Antalet som räknas är djuppunkter och inte foton. Det ser slarvigt ut men
    /// är rätt: nivån avgörs av riktningarnas SPRIDNING, och tio punkter ur samma
    /// bild pekar åt samma håll, så de kan aldrig av egen kraft göra en kub grön.
    mutating func add(_ keyframe: Keyframe, depth: [Float]) {
        let width = Int(keyframe.depthSize.x)
        let height = Int(keyframe.depthSize.y)
        guard width > 0, height > 0, depth.count >= width * height else { return }

        let step = max(1, Int((Float(width * height) / Float(Self.samplesPerFrame)).squareRoot()))
        let eye = keyframe.position

        for row in stride(from: 0, to: height, by: step) {
            for column in stride(from: 0, to: width, by: step) {
                let distance = depth[row * width + column]
                guard distance.isFinite,
                      distance > Self.minimumDistanceM,
                      distance < Self.maximumDistanceM else { continue }

                let point = keyframe.unproject(depthColumn: column,
                                               depthRow: row,
                                               distance: distance)
                let toCamera = eye - point
                let length = simd_length(toCamera)
                guard length > 0 else { continue }

                let scaled = point / Self.cellSizeM
                let cell = SIMD3<Int32>(Int32(scaled.x.rounded(.down)),
                                        Int32(scaled.y.rounded(.down)),
                                        Int32(scaled.z.rounded(.down)))
                var sighting = cells[cell] ?? Sighting()
                sighting.count += 1
                sighting.sum += toCamera / length
                cells[cell] = sighting
            }
        }
    }

    // MARK: - Kartan

    /// Rummet uppifrån, en ruta per kubkolumn.
    struct Map: Sendable {

        struct Tile: Sendable {
            /// Kubkoordinat, inte meter. Multiplicera med `cellSizeM`.
            let x: Int32
            let z: Int32
            let level: SurfaceCoverage.Level
        }

        let tiles: [Tile]
        /// Hur stor del av det uppmätta som setts från tillräckligt brett håll.
        let solidFraction: Double

        static let empty = Map(tiles: [], solidFraction: 0)
    }

    /// Kartan att rita, sedd rakt uppifrån.
    ///
    /// En kolumn får sin SÄMSTA kubs nivå. Golvet och allt över två meter räknas
    /// bort: golvet är alltid täckt och skulle lägga sig grönt över hela bilden,
    /// och taket är alltid tunt sett och skulle lägga sig gult över samma bild.
    /// Kvar blir bandet kunden faktiskt bryr sig om — väggar, bänkar, möbler.
    func map() -> Map {
        guard let lowest = cells.keys.map(\.y).min() else { return .empty }
        let ceiling = lowest + Int32((2.0 / Self.cellSizeM).rounded())

        var worst: [SIMD2<Int32>: SurfaceCoverage.Level] = [:]
        for (cell, sighting) in cells where cell.y > lowest && cell.y <= ceiling {
            let level = level(of: sighting)
            let column = SIMD2(cell.x, cell.z)
            if let existing = worst[column], existing.rawValue >= level.rawValue { continue }
            worst[column] = level
        }

        guard !worst.isEmpty else { return .empty }
        let solid = worst.values.reduce(into: 0) { total, level in
            if level == .solid { total += 1 }
        }
        return Map(tiles: worst.map { Map.Tile(x: $0.key.x, z: $0.key.y, level: $0.value) },
                   solidFraction: Double(solid) / Double(worst.count))
    }

    /// Aldrig `.missing` — en kub som inte setts finns inte i tabellen.
    private func level(of sighting: Sighting) -> SurfaceCoverage.Level {
        SurfaceCoverage.spread(count: Int(sighting.count), sum: sighting.sum)
            >= SurfaceCoverage.minimumSpreadDegrees ? .solid : .thin
    }
}
