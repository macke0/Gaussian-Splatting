//
//  CoverageMapView.swift
//  SpatialFit
//
//  Rummet uppifrån medan man filmar det, som en minikarta i hörnet.
//
//  Talen räcker inte. "62 % täckt" säger inte vart man ska gå, och det är det
//  enda kunden kan göra något åt medan hen står kvar. Kartan gör det: grönt är
//  klart, gult behöver ses från ett annat håll, och det tomma är sådant kameran
//  aldrig varit riktad mot. Pricken visar var man står och åt vilket håll.
//
//  Norr på kartan är rummets Z-axel, alltså den riktning skanningen började i.
//  Kartan vrids inte med telefonen — en karta som snurrar går inte att jämföra
//  med den man såg för tio sekunder sedan.
//

import SwiftUI

struct CoverageMapView: View {

    let map: LiveCoverage.Map
    /// Kamerans plats och blickriktning i golvplanet, i meter.
    let position: SIMD2<Float>
    let heading: SIMD2<Float>

    /// Så många meter runt omkring som får plats. Bredare och rutorna blir för
    /// små att se på en minikarta; smalare och man tappar rummet man kom från.
    private let radiusM: Float = 4

    var body: some View {
        Canvas { context, size in
            let scale = Float(min(size.width, size.height)) / (2 * radiusM)
            let middle = SIMD2(Float(size.width), Float(size.height)) / 2

            func place(_ world: SIMD2<Float>) -> CGPoint {
                // Z växer bakåt i världen men nedåt på skärmen, så den vänds.
                let offset = SIMD2(world.x - position.x, position.y - world.y) * scale
                return CGPoint(x: CGFloat(middle.x + offset.x),
                               y: CGFloat(middle.y + offset.y))
            }

            let side = CGFloat(LiveCoverage.cellSizeM * scale)
            for tile in map.tiles {
                let corner = SIMD2(Float(tile.x), Float(tile.z)) * LiveCoverage.cellSizeM
                let topLeft = place(SIMD2(corner.x, corner.y + LiveCoverage.cellSizeM))
                let square = CGRect(x: topLeft.x, y: topLeft.y, width: side, height: side)
                guard square.intersects(CGRect(origin: .zero, size: size)) else { continue }
                context.fill(Path(square), with: .color(Color(tile.level).opacity(0.85)))
            }

            context.fill(marker(at: place(position), size: size), with: .color(.white))
        }
        .background(.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(.white.opacity(0.25), lineWidth: 1)
        }
    }

    /// En pil i blickriktningen. Kartan är i världens koordinater, så pilen
    /// måste vridas — det är den som säger vilket håll man tittar åt.
    private func marker(at centre: CGPoint, size: CGSize) -> Path {
        let forward = SIMD2(heading.x, -heading.y)
        let side = SIMD2(-forward.y, forward.x)
        let length: Float = 9
        let width: Float = 5

        func point(_ offset: SIMD2<Float>) -> CGPoint {
            CGPoint(x: centre.x + CGFloat(offset.x), y: centre.y + CGFloat(offset.y))
        }

        var path = Path()
        path.move(to: point(forward * length))
        path.addLine(to: point(side * width - forward * width))
        path.addLine(to: point(-side * width - forward * width))
        path.closeSubpath()
        return path
    }
}

extension Color {
    /// Samma färger som den ritade mesh:en, så att gult betyder gult överallt.
    init(_ level: SurfaceCoverage.Level) {
        let tint = level.tint
        self.init(red: tint.red, green: tint.green, blue: tint.blue)
    }
}
