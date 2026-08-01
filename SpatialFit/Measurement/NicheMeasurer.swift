//
//  NicheMeasurer.swift
//  SpatialFit
//
//  Punktmoln + grovt utgångsläge → uppmätt nisch med ärlig osäkerhet.
//
//  Varje axel mäts som avståndet mellan två motstående YTOR, inte mellan två
//  punkter. Se PlaneFit.swift för varför det är skillnaden mellan centimeter
//  och millimeter.
//

import Foundation
import simd

/// Måttet på en axel plus hur mycket det går att lita på.
struct AxisMeasurement: Identifiable, Equatable, Sendable {
    let axis: Axis
    let extentMM: Double
    /// ± mm. Sammanvägt medelfel för de två ytorna, aldrig under
    /// `NicheMeasurer.systematicFloorMM`.
    let uncertaintyMM: Double
    /// `false` = minst en av ytorna gick inte att belägga, måttet kommer från
    /// utgångsläget. Ska visas i UI:t – det är inte ett mätvärde.
    let isMeasured: Bool
    /// Ytornas ojämnhet. Stort värde = passningen tog med något som inte är
    /// en plan yta, t.ex. en list, ett handtag eller en gardin.
    let surfaceRoughnessMM: Double

    var id: String { axis.rawValue }
}

/// Resultatet av en skanning, redo att bli en `Niche`.
struct NicheMeasurement: Equatable, Sendable {
    let dimensions: Dimensions3D
    let center: SIMD3<Float>
    let axes: [AxisMeasurement]

    /// Sämsta axelns osäkerhet – det är den som ska styra zonlogiken.
    var toleranceMM: Double {
        axes.map(\.uncertaintyMM).max() ?? 0
    }

    var isFullyMeasured: Bool {
        axes.allSatisfy(\.isMeasured)
    }

    func measurement(for axis: Axis) -> AxisMeasurement? {
        axes.first { $0.axis == axis }
    }

    /// Blir en nisch som motorn kan räkna på.
    func niche(id: String, label: String) -> Niche {
        Niche(id: id,
              label: label,
              dimensions: dimensions,
              source: isFullyMeasured ? .lidarRefined : .roomPlan,
              center: center,
              measuredToleranceMM: toleranceMM)
    }
}

enum NicheMeasurer {

    /// Under detta går vi inte, hur många punkter vi än medelvärdesbildar.
    ///
    /// σ/√n går mot noll, men verkligheten gör inte det: ARKits världsspårning
    /// driver, djupkameran har en systematisk skalfaktor, och skåpsidan är
    /// målad spånskiva som buktar. Att rapportera ±0,05 mm för ett kök vore
    /// ett falskt löfte – och det är precis den sortens löfte den här appen
    /// finns för att slippa.
    static let systematicFloorMM: Double = 1.0

    /// Mät nischen.
    ///
    /// - Parameters:
    ///   - samples: Ackumulerade djuppunkter i världskoordinater.
    ///   - seed: Grov utgångslåda – från RoomPlan, en användarmarkering eller
    ///     förra bildrutans mätning. Behöver bara vara rätt på några centimeter.
    ///   - searchRadius: Hur långt från utgångsytan punkter hämtas (m).
    ///   - fallbackToleranceMM: Osäkerheten som sätts på axlar som inte gick
    ///     att mäta – default RoomPlans nominella ±15 mm.
    static func measure(_ samples: [DepthSample],
                        seed: BoxAABB,
                        axes: [Axis] = Axis.allCases,
                        searchRadius: Float = 0.05,
                        minimumInliers: Int = 50,
                        fallbackToleranceMM: Double = MeasurementSource.roomPlan.nominalToleranceMM)
    -> NicheMeasurement {

        var dimensions = seed.dimensions
        var center = seed.center
        var results: [AxisMeasurement] = []

        for axis in Axis.allCases {
            guard axes.contains(axis) else {
                results.append(unmeasured(axis, seed: seed, tolerance: fallbackToleranceMM))
                continue
            }

            let direction = unitVector(axis)
            // Normalerna pekar in mot nischens mitt, så att positivt avstånd
            // alltid betyder "längre in i det fria utrymmet".
            let lowSeed = Plane(normal: direction, through: seed.minCorner)
            let highSeed = Plane(normal: -direction, through: seed.maxCorner)
            let window = searchWindow(for: axis, seed: seed, searchRadius: searchRadius)

            guard let low = PlaneFitter.fit(samples, seed: lowSeed,
                                            searchRadius: searchRadius,
                                            window: window,
                                            minimumInliers: minimumInliers),
                  let high = PlaneFitter.fit(samples, seed: highSeed,
                                             searchRadius: searchRadius,
                                             window: window,
                                             minimumInliers: minimumInliers)
            else {
                results.append(unmeasured(axis, seed: seed, tolerance: fallbackToleranceMM))
                continue
            }

            // Mät varje yta mot den andras tyngdpunkt och medelvärdesbilda.
            // Det ger rätt svar även när ytorna inte är exakt parallella –
            // vilket de aldrig är i ett riktigt kök.
            let lowToHigh = low.plane.signedDistance(to: high.centroid)
            let highToLow = high.plane.signedDistance(to: low.centroid)
            let extent = Double(lowToHigh + highToLow) / 2

            guard extent > 0 else {
                results.append(unmeasured(axis, seed: seed, tolerance: fallbackToleranceMM))
                continue
            }

            let combinedError = (low.standardErrorMM * low.standardErrorMM
                                 + high.standardErrorMM * high.standardErrorMM).squareRoot()

            dimensions[axis] = Float(extent).asMillimeters
            center[axis.simdIndex] = (simd_dot(direction, low.centroid)
                                      + simd_dot(direction, high.centroid)) / 2

            results.append(AxisMeasurement(
                axis: axis,
                extentMM: Float(extent).asMillimeters,
                uncertaintyMM: max(combinedError, systematicFloorMM),
                isMeasured: true,
                surfaceRoughnessMM: max(low.rmsResidualMM, high.rmsResidualMM)
            ))
        }

        return NicheMeasurement(dimensions: dimensions, center: center, axes: results)
    }

    // MARK: - Private

    private static func unmeasured(_ axis: Axis, seed: BoxAABB, tolerance: Double) -> AxisMeasurement {
        AxisMeasurement(axis: axis,
                        extentMM: seed.dimensions[axis],
                        uncertaintyMM: tolerance,
                        isMeasured: false,
                        surfaceRoughnessMM: 0)
    }

    /// Området en axels två ytor får sökas i: fullt utsträckt längs axeln
    /// själv, men indraget `cornerInset` på de andra två så att hörnen hamnar
    /// utanför. Se `PlaneFitter.fit(window:)` för varför.
    private static func searchWindow(for axis: Axis,
                                     seed: BoxAABB,
                                     searchRadius: Float) -> BoxAABB {
        var size = seed.size
        for other in Axis.allCases where other != axis {
            size[other.simdIndex] = max(size[other.simdIndex] - 2 * cornerInset,
                                        minimumWindowExtent)
        }
        size[axis.simdIndex] += 2 * searchRadius
        return BoxAABB(center: seed.center, size: size)
    }

    /// Hur långt in från hörnen mätningen håller sig (m).
    private static let cornerInset: Float = 0.06
    /// Skyddsnät för mycket små nischer – hellre lite hörn än inga punkter.
    private static let minimumWindowExtent: Float = 0.05

    private static func unitVector(_ axis: Axis) -> SIMD3<Float> {
        switch axis {
        case .width:  return SIMD3(1, 0, 0)
        case .height: return SIMD3(0, 1, 0)
        case .depth:  return SIMD3(0, 0, 1)
        }
    }
}
