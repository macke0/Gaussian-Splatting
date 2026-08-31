//
//  DepthMaps.swift
//  SpatialFit
//
//  Skanningens djupkartor inlästa i minnet, som en uppslagning per keyframe.
//
//  LiDAR ger 256×192 flyttal per bild — en dryg fjärdedels megabyte styck, små
//  nog att hålla allihop samtidigt. Det gör ocklusionstestet till en indexering
//  i stället för en filläsning per triangel.
//
//  Djupet är det som skiljer "syns i bilden" från "fotograferades". En vägg
//  bakom en spis projiceras in i bildrutan precis som spisen gör; utan
//  djupkartan målas väggen rakt över spisen, och en täckningsmätning skulle
//  påstå att ytan bakom möblerna är fotograferad.
//

import Foundation

struct DepthMaps: Sendable {

    private let maps: [Int: [Float]]

    init(keyframes: [Keyframe], directory: URL) {
        var maps: [Int: [Float]] = [:]
        for keyframe in keyframes where keyframe.depthSize.x > 0 {
            let url = directory.appending(path: keyframe.depthFilename)
            guard let data = try? Data(contentsOf: url) else { continue }
            let count = Int(keyframe.depthSize.x) * Int(keyframe.depthSize.y)
            guard data.count >= count * MemoryLayout<Float>.size else { continue }
            maps[keyframe.id] = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        }
        self.maps = maps
    }

    var isEmpty: Bool { maps.isEmpty }

    var lookup: ViewSelection.DepthLookup {
        let maps = self.maps
        return { keyframe, index in
            guard let map = maps[keyframe.id], index >= 0, index < map.count else { return nil }
            let value = map[index]
            return value.isFinite && value > 0 ? value : nil
        }
    }
}
