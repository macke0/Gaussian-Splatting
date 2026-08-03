//
//  ObjectCrop.swift
//  SpatialFit
//
//  Vilket foto visar den här pjäsen bäst, och var i bilden ligger den?
//
//  RoomPlan säger att något ÄR en spis och hur stor lådan är. Vad för slags spis
//  syns bara i fotot — men bara om man klipper ut rätt bit. Ett helt foto av ett
//  kök beskrivs som "ett kök"; det är utsnittet som gör svaret användbart.
//
//  Urvalet är avsiktligt strängt: alla åtta hörn av lådan måste synas i bilden.
//  Ett halvt skåp beskrivs fel, och hellre inget svar än ett påhittat.
//
//  Ren simd och Foundation. Själva bildklippet ligger i lagret ovanför.
//

import Foundation
import simd

enum ObjectCrop {

    /// Utsnittet växer med en femtedel åt varje håll. Modellen behöver se
    /// omgivningen för att förstå vad den tittar på — ett skåp utan golv och
    /// bänk bredvid är bara en färgad yta.
    static let marginFraction: Float = 0.2

    /// Ett utsnitt att skicka iväg, i pixlar.
    struct Crop: Equatable, Sendable {
        let keyframeID: Int
        let origin: SIMD2<Float>
        let size: SIMD2<Float>
        /// Bildstorleken rutan är uttryckt i. JPEG:en på disk kan ha en annan
        /// upplösning än den `Keyframe` räknade med, och då måste rutan skalas.
        let imageSize: SIMD2<Float>

        var area: Float { size.x * size.y }
    }

    /// Bästa utsnittet för ett element, eller `nil` om ingen bild såg hela det.
    ///
    /// Bland de bilder som ser hela lådan vinner den som ser den störst — alltså
    /// närmast och mest rakt på. Ett litet utsnitt är ett suddigt utsnitt.
    static func best(for element: RoomElement, in keyframes: [Keyframe]) -> Crop? {
        let corners = self.corners(of: element)

        var best: Crop?
        for keyframe in keyframes {
            guard let crop = crop(of: corners, in: keyframe) else { continue }
            if best == nil || crop.area > best!.area {
                best = crop
            }
        }
        return best
    }

    /// Lådans åtta hörn i världskoordinater.
    static func corners(of element: RoomElement) -> [SIMD3<Float>] {
        let half = element.dimensions / 2
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(8)

        for x in [-half.x, half.x] {
            for y in [-half.y, half.y] {
                for z in [-half.z, half.z] {
                    let point = element.transform * SIMD4<Float>(x, y, z, 1)
                    result.append(SIMD3(point.x, point.y, point.z))
                }
            }
        }
        return result
    }

    private static func crop(of corners: [SIMD3<Float>], in keyframe: Keyframe) -> Crop? {
        var lower = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var upper = SIMD2<Float>(-.greatestFiniteMagnitude, -.greatestFiniteMagnitude)

        for corner in corners {
            // `project` ger nil så snart hörnet hamnar utanför bilden, vilket är
            // precis kravet: hela lådan ska synas.
            guard let projection = keyframe.project(corner) else { return nil }
            lower = simd_min(lower, projection.pixel)
            upper = simd_max(upper, projection.pixel)
        }

        let margin = (upper - lower) * marginFraction
        let expanded = (origin: lower - margin, corner: upper + margin)
        let clamped = (origin: simd_max(expanded.origin, SIMD2(0, 0)),
                       corner: simd_min(expanded.corner, keyframe.imageSize))

        let size = clamped.corner - clamped.origin
        guard size.x >= 1, size.y >= 1 else { return nil }
        return Crop(keyframeID: keyframe.id, origin: clamped.origin, size: size,
                    imageSize: keyframe.imageSize)
    }
}
