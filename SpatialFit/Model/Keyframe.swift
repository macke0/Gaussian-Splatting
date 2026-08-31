//
//  Keyframe.swift
//  SpatialFit
//
//  En kamerabild med känd placering, sparad under skanningen. Det är råvaran
//  för att måla riktiga foton på rummets mesh i stället för grå plast.
//
//  Bilden ligger som JPEG bredvid, djupkartan som råa Float32. Djupet används
//  för att avgöra om en yta faktiskt syntes i bilden eller låg bakom något
//  annat — utan det testet smetas väggen bakom en spis ut över spisen.
//
//  Ren simd och Foundation. ARKit-beroendet ligger i lagret ovanför.
//

import Foundation
import simd

struct Keyframe: Codable, Sendable, Identifiable, Equatable {

    let id: Int
    /// Djupkartans upplösning. LiDAR ger 256×192 oavsett bildstorlek.
    let depthSize: SIMD2<Int32>
    /// Färgbildens storlek i pixlar, efter nedskalning.
    let imageSize: SIMD2<Float>

    private let cameraFromWorldColumns: [SIMD4<Float>]
    private let intrinsicsColumns: [SIMD3<Float>]

    init(id: Int,
         worldFromCamera: simd_float4x4,
         intrinsics: simd_float3x3,
         imageSize: SIMD2<Float>,
         depthSize: SIMD2<Int32>) {
        self.id = id
        self.imageSize = imageSize
        self.depthSize = depthSize
        let inverse = worldFromCamera.inverse
        self.cameraFromWorldColumns = [inverse.columns.0, inverse.columns.1,
                                       inverse.columns.2, inverse.columns.3]
        self.intrinsicsColumns = [intrinsics.columns.0, intrinsics.columns.1,
                                  intrinsics.columns.2]
    }

    var cameraFromWorld: simd_float4x4 {
        simd_float4x4(cameraFromWorldColumns[0], cameraFromWorldColumns[1],
                      cameraFromWorldColumns[2], cameraFromWorldColumns[3])
    }

    var intrinsics: simd_float3x3 {
        simd_float3x3(intrinsicsColumns[0], intrinsicsColumns[1], intrinsicsColumns[2])
    }

    var worldFromCamera: simd_float4x4 { cameraFromWorld.inverse }

    /// Kamerans plats i världen.
    var position: SIMD3<Float> {
        let column = worldFromCamera.columns.3
        return SIMD3(column.x, column.y, column.z)
    }

    var imageFilename: String { "kf\(id).jpg" }
    var depthFilename: String { "kf\(id).depth" }

    // MARK: - Projektion

    /// Var en världspunkt hamnar i bilden, och hur långt bort den är.
    ///
    /// ARKits kamerarum har Y uppåt och Z bakåt, medan `intrinsics` räknar med
    /// den klassiska hålkamerakonventionen (Y nedåt, Z framåt). Därför byter
    /// två tecken plats innan projektionen.
    func project(_ world: SIMD3<Float>) -> Projection? {
        let camera = cameraFromWorld * SIMD4<Float>(world, 1)
        let depth = -camera.z
        guard depth > 0.05 else { return nil }

        let pinhole = SIMD3<Float>(camera.x, -camera.y, depth)
        let image = intrinsics * pinhole
        let pixel = SIMD2(image.x / image.z, image.y / image.z)

        guard pixel.x >= 0, pixel.y >= 0,
              pixel.x < imageSize.x, pixel.y < imageSize.y else { return nil }

        return Projection(pixel: pixel, depth: depth)
    }

    struct Projection: Equatable, Sendable {
        /// Pixelkoordinat i den sparade bilden.
        let pixel: SIMD2<Float>
        /// Avstånd rakt framåt från kameran, i meter.
        let depth: Float

        /// Normaliserad texturkoordinat. V vänds, för att bildens rad 0 ligger
        /// överst medan texturens V växer nedåt i RealityKit.
        func textureCoordinate(imageSize: SIMD2<Float>) -> SIMD2<Float> {
            SIMD2(pixel.x / imageSize.x, pixel.y / imageSize.y)
        }
    }

    /// Motsatsen till `project`: en punkt i djupkartan tillbaka ut i världen.
    ///
    /// Det är så man får veta VAD kameran såg, inte bara om en känd yta råkade
    /// hamna i bild. Under skanningen finns ingen färdig mesh att fråga, så
    /// täckningen måste byggas ur djupet självt.
    ///
    /// - Parameter distance: LiDAR-avståndet, mätt rakt framåt längs kamerans
    ///   blick — inte fågelvägen till punkten.
    func unproject(depthColumn: Int, depthRow: Int, distance: Float) -> SIMD3<Float> {
        // Djupkartan är grövre än bilden men täcker samma synfält, så pixeln
        // skalas upp innan `intrinsics` vänds.
        let pixel = SIMD2(Float(depthColumn) + 0.5, Float(depthRow) + 0.5)
            / SIMD2(Float(depthSize.x), Float(depthSize.y)) * imageSize
        let ray = intrinsics.inverse * SIMD3<Float>(pixel.x, pixel.y, 1)

        // Tillbaka från hålkamera till ARKits kamerarum: y upp, z bakåt.
        let camera = SIMD4<Float>(ray.x * distance, -ray.y * distance, -distance, 1)
        let world = worldFromCamera * camera
        return SIMD3(world.x, world.y, world.z)
    }

    /// Index i djupkartan för en projicerad pixel.
    func depthIndex(for pixel: SIMD2<Float>) -> Int {
        let column = Int((pixel.x / imageSize.x) * Float(depthSize.x))
        let row = Int((pixel.y / imageSize.y) * Float(depthSize.y))
        let clampedColumn = min(max(column, 0), Int(depthSize.x) - 1)
        let clampedRow = min(max(row, 0), Int(depthSize.y) - 1)
        return clampedRow * Int(depthSize.x) + clampedColumn
    }
}
