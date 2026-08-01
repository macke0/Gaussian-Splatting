//
//  DepthSample.swift
//  SpatialFit
//
//  En avläst punkt ur LiDAR-djupkartan, transformerad till världskoordinater.
//  Detta är gränssnittet mellan hårdvaran och mätmatematiken: allt ovanför den
//  här typen är ren geometri som går att testa utan enhet.
//

import Foundation
import simd

/// En djuppunkt i världskoordinater (METER, som RealityKit och ARKit).
///
/// `confidence` är ARKits `ARConfidenceLevel` normaliserad till 0…1
/// (low = 0, medium = 0,5, high = 1). Låg konfidens betyder oftast reflekterande
/// eller mörk yta – blanka vitvarufronter och svart kakel är exakt de ytor en
/// köksmätning råkar på, så filtret behövs.
struct DepthSample: Equatable, Sendable {
    var position: SIMD3<Float>
    var confidence: Float

    init(position: SIMD3<Float>, confidence: Float = 1) {
        self.position = position
        self.confidence = confidence
    }
}
