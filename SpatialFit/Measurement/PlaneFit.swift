//
//  PlaneFit.swift
//  SpatialFit
//
//  Robust planpassning mot ett LiDAR-punktmoln.
//
//  Det här är svaret på "hur får man millimeterprecision ur en sensor som har
//  centimeterprecision": man mäter inte punkter, man mäter YTOR. En enskild
//  LiDAR-punkt ligger ±10 mm fel, men medelfelet för ett plan passat genom
//  n punkter är σ/√n. Med 2 000 punkter mot en skåpsida blir planets läge känt
//  på ~0,2 mm – förutsatt att bruset är osystematiskt.
//
//  Därför rapporterar `PlaneFit` både spridningen (`rmsResidualMM`, hur ojämn
//  ytan är) och medelfelet (`standardErrorMM`, hur säkert planet ligger).
//  Det är det andra talet som blir nischens mätosäkerhet, och det första som
//  avslöjar att man råkat passa ett plan mot en gardin.
//

import Foundation
import simd

/// Ett oändligt plan: alla punkter p där `dot(normal, p) == offset`.
/// `normal` är enhetslång och pekar per konvention IN i nischen.
struct Plane: Equatable, Sendable {
    var normal: SIMD3<Float>
    var offset: Float

    init(normal: SIMD3<Float>, offset: Float) {
        let length = simd_length(normal)
        self.normal = length > 0 ? normal / length : SIMD3(0, 1, 0)
        self.offset = length > 0 ? offset / length : offset
    }

    /// Planet genom `point` med given normal.
    init(normal: SIMD3<Float>, through point: SIMD3<Float>) {
        let unit = simd_normalize(normal)
        self.normal = unit
        self.offset = simd_dot(unit, point)
    }

    /// Positivt = punkten ligger på normalens sida, dvs. inne i nischen.
    func signedDistance(to point: SIMD3<Float>) -> Float {
        simd_dot(normal, point) - offset
    }
}

/// Resultatet av en passning, med den statistik som behövs för att avgöra
/// om måttet går att lita på.
struct PlaneFit: Equatable, Sendable {
    let plane: Plane
    /// Tyngdpunkten för de punkter som passningen byggde på. Används för att
    /// mäta avstånd mellan två ytor utan att förutsätta att de är parallella.
    let centroid: SIMD3<Float>
    let inlierCount: Int
    /// Punkternas spridning kring planet – ytans ojämnhet plus sensorbrus.
    let rmsResidualMM: Double

    /// Medelfelet för planets LÄGE: σ/√n. Detta är nischmåttets osäkerhet.
    var standardErrorMM: Double {
        guard inlierCount > 0 else { return .infinity }
        return rmsResidualMM / Double(inlierCount).squareRoot()
    }
}

enum PlaneFitter {

    /// Hur mycket en punkt får avvika från arbetsplanet för att räknas med,
    /// uttryckt i robust skattade standardavvikelser.
    private static let outlierSigmas: Float = 2.5
    /// Golv för avvisningströskeln (m). Utan det kollapsar slabben mot ett
    /// perfekt plan i syntetisk data och kastar bort allt.
    private static let minimumRejectionMeters: Float = 0.002

    /// Skalfaktorn som gör medianavvikelsen jämförbar med en standardavvikelse
    /// för normalfördelat brus.
    private static let madToSigma: Float = 1.4826

    /// Passa ett plan till de punkter som ligger nära `seed`.
    ///
    /// Startar med medianen längs utgångsnormalen i stället för att gå direkt
    /// på minstakvadrat. Anledningen är konkret: söker man en skåpsida i en
    /// 50 mm-skiva får man med en remsa av golvet där de möts, och den remsan
    /// står vinkelrätt mot planet man letar efter. Minstakvadrat viktar alla
    /// punkter lika och vrider planet; medianen bryr sig inte.
    ///
    /// - Parameters:
    ///   - seed: Grovt utgångsplan – från RoomPlan, en användartapp eller
    ///     nischens antagna form. Bestämmer både vilka punkter som är
    ///     kandidater och åt vilket håll normalen ska peka.
    ///   - searchRadius: Halva tjockleken (m) på skivan kring `seed` som
    ///     punkter hämtas ur. För bred → grannytan dras in i passningen.
    ///   - window: Området ytan får sökas i. Utan det drar en skåpsidas skiva
    ///     med sig remsor av golv, bakvägg och bänkskiva där de möts. Den
    ///     kontamineringen ligger alltid på samma sida om ytan, så den flyttar
    ///     måttet flera millimeter i stället för att bara bullra – medianen
    ///     räddar inte det. Mät mitt på ytan; hörn är både geometriskt
    ///     tvetydiga och där LiDAR:n är som sämst.
    ///   - minimumConfidence: Punkter under detta kastas direkt.
    ///   - minimumInliers: Färre än så och måttet är inte försvarbart.
    /// - Returns: `nil` om ytan inte gick att belägga.
    static func fit(_ samples: [DepthSample],
                    seed: Plane,
                    searchRadius: Float = 0.05,
                    window: BoxAABB? = nil,
                    minimumConfidence: Float = 0.5,
                    minimumInliers: Int = 50) -> PlaneFit? {

        let candidates = samples
            .filter { $0.confidence >= minimumConfidence }
            .map(\.position)
            .filter { abs(seed.signedDistance(to: $0)) <= searchRadius }
            .filter { window?.contains($0) ?? true }
        guard candidates.count >= minimumInliers else { return nil }

        // Steg 1: lås normalen, hitta ytans läge robust.
        let offsets = candidates.map { seed.signedDistance(to: $0) }
        var plane = Plane(normal: seed.normal, offset: seed.offset + median(offsets))
        var tolerance = rejectionThreshold(for: candidates, against: plane)

        // Steg 2: släpp normalen fri så att den rätar upp sig mot ytan. Det är
        // det som gör att en vriden vägg mäts rätt utan att motorn behöver
        // veta att den är vriden.
        var inliers: [SIMD3<Float>] = []
        for _ in 0..<3 {
            inliers = candidates.filter { abs(plane.signedDistance(to: $0)) <= tolerance }
            guard inliers.count >= minimumInliers else { return nil }

            guard let refined = leastSquaresPlane(inliers, orientedLike: seed.normal) else { return nil }
            plane = refined
            tolerance = rejectionThreshold(for: inliers, against: plane)
        }

        inliers = candidates.filter { abs(plane.signedDistance(to: $0)) <= tolerance }
        guard inliers.count >= minimumInliers else { return nil }

        let sigma = rootMeanSquare(of: inliers, against: plane)
        let centroid = inliers.reduce(SIMD3<Float>.zero, +) / Float(inliers.count)

        return PlaneFit(plane: plane,
                        centroid: centroid,
                        inlierCount: inliers.count,
                        rmsResidualMM: Float(sigma).asMillimeters)
    }

    // MARK: - Robust statistik

    private static func rejectionThreshold(for points: [SIMD3<Float>], against plane: Plane) -> Float {
        let deviations = points.map { abs(plane.signedDistance(to: $0)) }
        return max(madToSigma * median(deviations) * outlierSigmas, minimumRejectionMeters)
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    // MARK: - Minstakvadratpassning

    /// Planet som minimerar summan av kvadrerade avstånd = tyngdpunkten plus
    /// kovariansmatrisens minsta egenvektor.
    private static func leastSquaresPlane(_ points: [SIMD3<Float>],
                                          orientedLike reference: SIMD3<Float>) -> Plane? {
        guard points.count >= 3 else { return nil }

        var mean = SIMD3<Double>.zero
        for p in points { mean += SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) }
        mean /= Double(points.count)

        var xx = 0.0, xy = 0.0, xz = 0.0, yy = 0.0, yz = 0.0, zz = 0.0
        for p in points {
            let d = SIMD3<Double>(Double(p.x), Double(p.y), Double(p.z)) - mean
            xx += d.x * d.x; xy += d.x * d.y; xz += d.x * d.z
            yy += d.y * d.y; yz += d.y * d.z; zz += d.z * d.z
        }

        let covariance = [[xx, xy, xz],
                          [xy, yy, yz],
                          [xz, yz, zz]]
        guard let smallest = smallestEigenvector(of: covariance) else { return nil }

        var normal = SIMD3<Float>(Float(smallest.x), Float(smallest.y), Float(smallest.z))
        // Egenvektorns tecken är godtyckligt – lås det mot utgångsnormalen så
        // att "in i nischen" fortsätter betyda samma sak.
        if simd_dot(normal, reference) < 0 { normal = -normal }

        let centroid = SIMD3<Float>(Float(mean.x), Float(mean.y), Float(mean.z))
        return Plane(normal: normal, through: centroid)
    }

    private static func rootMeanSquare(of points: [SIMD3<Float>], against plane: Plane) -> Double {
        guard !points.isEmpty else { return 0 }
        var sum = 0.0
        for p in points {
            let d = Double(plane.signedDistance(to: p))
            sum += d * d
        }
        return (sum / Double(points.count)).squareRoot()
    }

    // MARK: - Egenvektor

    /// Egenvektorn till det minsta egenvärdet i en symmetrisk 3×3-matris,
    /// via cyklisk Jacobi-rotation. Matrisen ges radvis.
    ///
    /// Analytiska formler för symmetriska 3×3 finns, men de tappar precision
    /// när två egenvärden ligger nära varandra – vilket är precis vad en
    /// plan yta ger (två stora, ett litet). Jacobi är stabil där.
    private static func smallestEigenvector(of matrix: [[Double]]) -> SIMD3<Double>? {
        var a = matrix
        var v = [[1.0, 0, 0], [0, 1.0, 0], [0, 0, 1.0]]

        for _ in 0..<32 {
            // Största elementet utanför diagonalen avgör vilken rotation som görs.
            var p = 0, q = 1
            var largest = abs(a[0][1])
            if abs(a[0][2]) > largest { largest = abs(a[0][2]); p = 0; q = 2 }
            if abs(a[1][2]) > largest { largest = abs(a[1][2]); p = 1; q = 2 }
            if largest < 1e-18 { break }

            let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
            let sign = theta >= 0 ? 1.0 : -1.0
            let t = sign / (abs(theta) + (theta * theta + 1).squareRoot())
            let c = 1 / (t * t + 1).squareRoot()
            let s = t * c

            for k in 0..<3 {
                let akp = a[k][p], akq = a[k][q]
                a[k][p] = c * akp - s * akq
                a[k][q] = s * akp + c * akq
            }
            for k in 0..<3 {
                let apk = a[p][k], aqk = a[q][k]
                a[p][k] = c * apk - s * aqk
                a[q][k] = s * apk + c * aqk
            }
            for k in 0..<3 {
                let vkp = v[k][p], vkq = v[k][q]
                v[k][p] = c * vkp - s * vkq
                v[k][q] = s * vkp + c * vkq
            }
        }

        let eigenvalues = [a[0][0], a[1][1], a[2][2]]
        guard let index = eigenvalues.indices.min(by: { eigenvalues[$0] < eigenvalues[$1] }) else {
            return nil
        }
        let vector = SIMD3<Double>(v[0][index], v[1][index], v[2][index])
        let length = simd_length(vector)
        guard length > 1e-12 else { return nil }
        return vector / length
    }
}
