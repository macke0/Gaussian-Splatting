//
//  NicheFinder.swift
//  SpatialFit
//
//  Skannat rum → nisch + hinder, uttryckt i NISCHENS EGET KOORDINATSYSTEM.
//
//  Det sista ledet är poängen. README:s första kända begränsning var att
//  motorn räknar axelriktat medan riktiga kök står snett i rummet. Lösningen
//  är inte att göra motorn tyngre med OBB och SAT, utan att välja rätt
//  koordinatsystem: bygg en ortonormal bas ur väggen (längs, upp, ut) och
//  projicera in produkt och hinder i den. Då står nischen rakt per definition
//  och AABB-matematiken i `CollisionEngine` är giltig igen – oavsett hur
//  rummet är vridet mot ARKits världsaxlar.
//
//  Basen läggs så att den matchar mockens konvention exakt: origo i golvhöjd,
//  mitt i nischens bredd, mitt i dess djup. `FitSceneController` och
//  `CollisionEngine.placement` fungerar därför oförändrade mot en riktig
//  skanning.
//

import Foundation
import simd

/// En nisch som hittats i ett skannat rum, plus var i världen den sitter.
struct ScannedNiche: NicheSource, Identifiable, Sendable {
    let niche: Niche
    let obstacles: [Obstacle]
    /// Nischens lokala system → världen. Sätts på `AnchorEntity`-transformen
    /// så att scenen hamnar rätt i passthrough-vyn.
    let worldFromNiche: simd_float4x4

    var id: String { niche.id }
}

enum NicheFinder {

    struct Options: Sendable {
        /// Smalare än så är ingen produktnisch, det är en springa mellan skåp.
        var minimumWidthMM: Double = 300
        /// Bredare än så är det inte en nisch utan en tom väggsträcka.
        var maximumWidthMM: Double = 1400
        var minimumHeightMM: Double = 300
        var minimumDepthMM: Double = 200
        /// Hur långt ett skåps BAKKANT får ligga från väggen och ändå räknas
        /// som en nischsida. Fångar upp sockelspringor och skannerns brus utan
        /// att dra in möbler som står mitt i rummet.
        var maximumStandoffMM: Double = 250
        /// Hur långt runt nischen hinder tas med.
        var obstacleRangeMM: Double = 2000

        init() {}
    }

    /// Alla nischer i ett skannat rum, störst fri volym först.
    ///
    /// Att den här returnerar en lista och inte ett svar är avsiktligt: vilken
    /// nisch kunden menar är en UI-fråga, inte en geometrisk. I appen pekar
    /// användaren ut den; listan finns för att kunna erbjuda valen.
    static func niches(in elements: [RoomElement], options: Options = Options()) -> [ScannedNiche] {
        let walls = elements.filter { $0.category == .wall }
        let furniture = elements.filter { $0.category == .furniture }
        let openings = elements.filter { $0.category == .opening }
        let floorLevel = floorLevel(of: elements)

        return walls
            .flatMap { wall in
                niches(along: wall,
                       furniture: furniture,
                       openings: openings,
                       elements: elements,
                       floorLevel: floorLevel,
                       options: options)
            }
            .sorted { lhs, rhs in
                let l = lhs.niche.dimensions, r = rhs.niche.dimensions
                return l.width * l.height * l.depth > r.width * r.height * r.depth
            }
    }

    // MARK: - Per vägg

    private static func niches(along wall: RoomElement,
                               furniture: [RoomElement],
                               openings: [RoomElement],
                               elements: [RoomElement],
                               floorLevel: Float,
                               options: Options) -> [ScannedNiche] {

        guard var frame = WallFrame(wall: wall) else { return [] }

        // Väggens normal har godtyckligt tecken i skanningen. Rummet ligger på
        // den sida där möblerna står – låt dem rösta, och vänd `along` med så
        // att basen förblir högerorienterad.
        let nearby = furniture.filter { frame.isNear($0, wall: wall, range: options.obstacleRangeMM.asMeters) }
        let side = nearby.reduce(Float(0)) { $0 + frame.outward(of: $1.center, from: wall.center) }
        if side < 0 { frame.flip() }

        let flanks = nearby
            .compactMap { Flank(element: $0, wall: wall, frame: frame, options: options) }
            .sorted { $0.alongMin < $1.alongMin }
        guard flanks.count >= 2 else { return [] }

        let openingSpans = openings.map { opening -> ClosedRange<Float> in
            let a = frame.along(of: opening.center, from: wall.center)
            let half = opening.halfExtent(along: frame.along)
            return (a - half)...(a + half)
        }

        var result: [ScannedNiche] = []
        for (index, pair) in zip(flanks, flanks.dropFirst()).enumerated() {
            let (left, right) = pair
            let widthMM = (right.alongMin - left.alongMax).asMillimeters
            guard widthMM >= options.minimumWidthMM, widthMM <= options.maximumWidthMM else { continue }

            let heightMM = (min(left.top, right.top) - floorLevel).asMillimeters
            guard heightMM >= options.minimumHeightMM else { continue }

            let depthMM = min(left.front, right.front).asMillimeters
            guard depthMM >= options.minimumDepthMM else { continue }

            // En dörr eller ett fönster mellan skåpen är ingen nisch – där kan
            // inget stå, även om gapet mäter rätt.
            let span = left.alongMax...right.alongMin
            guard !openingSpans.contains(where: { $0.overlaps(span) }) else { continue }

            let dimensions = Dimensions3D(widthMM, heightMM, depthMM)
            let origin = frame.worldPoint(along: (left.alongMax + right.alongMin) / 2,
                                          outward: depthMM.asMeters / 2,
                                          height: floorLevel,
                                          from: wall.center)
            let worldFromNiche = frame.transform(origin: origin)

            let niche = Niche(
                id: "\(wall.id)-nisch-\(index)",
                label: "Nisch mellan \(left.element.detail ?? "skåp") och \(right.element.detail ?? "skåp")",
                dimensions: dimensions,
                source: .roomPlan,
                center: SIMD3(0, dimensions.height.asMeters / 2, 0)
            )

            result.append(ScannedNiche(
                niche: niche,
                obstacles: obstacles(around: origin,
                                     frame: frame,
                                     elements: elements,
                                     dimensions: dimensions,
                                     options: options),
                worldFromNiche: worldFromNiche
            ))
        }
        return result
    }

    // MARK: - Hinder

    /// Rummets element uttryckta som axelriktade lådor i nischens system.
    ///
    /// Ett vridet skåp blir här den minsta axelriktade låda som omsluter det.
    /// Mot väggens egen bas är den approximationen tät för allt som står längs
    /// väggen – och ett skåp som står snett mot sin egen vägg är i praktiken
    /// felskannat, inte snett.
    private static func obstacles(around origin: SIMD3<Float>,
                                  frame: WallFrame,
                                  elements: [RoomElement],
                                  dimensions: Dimensions3D,
                                  options: Options) -> [Obstacle] {
        let range = options.obstacleRangeMM.asMeters
        let halfWidth = dimensions.width.asMeters / 2

        return elements.compactMap { element -> Obstacle? in
            var box = frame.localBox(of: element, origin: origin)

            // RoomPlan ger väggar och golv försumbar tjocklek. En låda utan
            // volym kan aldrig krocka; ge den 10 mm och skjut den bakåt så att
            // dess FRAMSIDA blir kvar där skanningen såg den.
            if element.category != .furniture {
                let axis = element.category == .floor ? 1 : 2
                let minimum: Float = 0.010
                if box.size[axis] < minimum {
                    let growth = minimum - box.size[axis]
                    box.size[axis] = minimum
                    box.center[axis] -= growth / 2
                }
            }

            guard abs(box.center.x) <= range + halfWidth,
                  abs(box.center.y) <= range,
                  box.center.z <= range,
                  box.center.z >= -range else { return nil }

            return Obstacle(id: element.id,
                            kind: element.category.obstacleKind,
                            box: box,
                            isCollidable: element.category.isCollidable)
        }
    }

    // MARK: - Golvnivå

    /// Golvytan om skanningen hittade en, annars underkanten på det som står
    /// i rummet. Nischens höjd mäts härifrån.
    private static func floorLevel(of elements: [RoomElement]) -> Float {
        if let floor = elements.first(where: { $0.category == .floor }) {
            return floor.center.y
        }
        let bottoms = elements
            .filter { $0.category == .furniture }
            .map { $0.center.y - $0.halfExtent(along: SIMD3(0, 1, 0)) }
        return bottoms.min() ?? 0
    }
}

// MARK: - Väggens koordinatsystem

/// Ortonormal bas ur en vägg: `along` längs väggen, `up` rakt upp,
/// `outward` ut i rummet. Högerorienterad, så transformen är en ren rotation.
private struct WallFrame {
    private(set) var along: SIMD3<Float>
    private(set) var outward: SIMD3<Float>
    let up = SIMD3<Float>(0, 1, 0)

    init?(wall: RoomElement) {
        // Väggens egen X-axel går längs den. Projicera ner i horisontalplanet
        // så att en vägg som skannats någon grad ur lod ändå ger en lodrät bas
        // – nischens höjd ska mätas mot gravitationen, inte mot väggen.
        var direction = wall.localAxis(0)
        direction.y = 0
        guard simd_length(direction) > 1e-3 else { return nil }
        along = simd_normalize(direction)
        outward = simd_cross(along, SIMD3(0, 1, 0))
    }

    mutating func flip() {
        along = -along
        outward = -outward
    }

    func along(of point: SIMD3<Float>, from wallCenter: SIMD3<Float>) -> Float {
        simd_dot(point - wallCenter, along)
    }

    func outward(of point: SIMD3<Float>, from wallCenter: SIMD3<Float>) -> Float {
        simd_dot(point - wallCenter, outward)
    }

    func isNear(_ element: RoomElement, wall: RoomElement, range: Float) -> Bool {
        let delta = element.center - wall.center
        let lateral = abs(simd_dot(delta, along))
        let distance = abs(simd_dot(delta, outward))
        return lateral <= wall.halfExtent(along: along) + range && distance <= range
    }

    func worldPoint(along a: Float, outward o: Float, height y: Float, from wallCenter: SIMD3<Float>) -> SIMD3<Float> {
        var point = wallCenter + along * a + outward * o
        point.y = y
        return point
    }

    func transform(origin: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(columns: (SIMD4(along, 0),
                                SIMD4(up, 0),
                                SIMD4(outward, 0),
                                SIMD4(origin, 1)))
    }

    /// Elementets omslutande axelriktade låda i nischens system.
    func localBox(of element: RoomElement, origin: SIMD3<Float>) -> BoxAABB {
        let delta = element.center - origin
        let center = SIMD3(simd_dot(delta, along), simd_dot(delta, up), simd_dot(delta, outward))
        let size = SIMD3(element.halfExtent(along: along) * 2,
                         element.halfExtent(along: up) * 2,
                         element.halfExtent(along: outward) * 2)
        return BoxAABB(center: center, size: size)
    }
}

// MARK: - Nischens sida

/// Ett möbelelement som kan bilda en nischsida, uttryckt i väggens system.
private struct Flank {
    let element: RoomElement
    let alongMin: Float
    let alongMax: Float
    /// Överkant i världens höjdled – nischens tak.
    let top: Float
    /// Hur långt ut från väggen elementet når. Nischens djup.
    let front: Float

    init?(element: RoomElement, wall: RoomElement, frame: WallFrame, options: NicheFinder.Options) {
        let a = frame.along(of: element.center, from: wall.center)
        let halfAlong = element.halfExtent(along: frame.along)
        let out = frame.outward(of: element.center, from: wall.center)
        let halfOut = element.halfExtent(along: frame.outward)

        // Bakkanten måste ligga an mot väggen. En köksö har rätt mått men fel
        // plats, och utan det här kravet blir gapet mellan ön och skåpsraden
        // en "nisch".
        guard out - halfOut <= options.maximumStandoffMM.asMeters, out > 0 else { return nil }

        self.element = element
        alongMin = a - halfAlong
        alongMax = a + halfAlong
        top = element.center.y + element.halfExtent(along: SIMD3(0, 1, 0))
        front = out + halfOut
    }
}
