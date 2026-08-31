//
//  KeyframeRecorder.swift
//  SpatialFit
//
//  Sparar kamerabilder med känd placering medan RoomPlan skannar. RoomPlan
//  exponerar sin `arSession`, så bilderna kan hämtas utan att störa skanningen
//  — sessionens delegat lämnas orörd och bildrutorna pollas i stället.
//
//  En bildruta blir en keyframe först när kameran flyttat eller vridit sig
//  tillräckligt. Annars fylls disken med fyrtio bilder av samma vägg.
//
//  Den som skannar går medan bilden tas, så var tredje bildruta är rörelseoskarp.
//  Mätt på ett riktigt rum skilde det fyra gånger mellan den skarpaste och den
//  suddigaste bilden, och bakningen blandar ihop dem. Därför vägs skärpan innan
//  bilden sparas: är den mycket sämre än de tidigare väntar vi några bildrutor
//  på en bättre.
//

import Foundation
import ARKit
import CoreImage
import UIKit

@MainActor
final class KeyframeRecorder {

    private(set) var keyframes: [Keyframe] = []

    /// Täckningen som byggts ur de sparade bildernas djupkartor. Byggs här och
    /// inte i modellen ovanför för att djupet redan är uppackat på det här
    /// stället — annars skulle kartan läsa tillbaka filerna vi just skrev.
    private(set) var coverage = LiveCoverage()

    private let directory: URL
    private let maximumCount: Int
    /// Bredd i pixlar på den sparade bilden. Ska följa atlasens upplösning:
    /// vid 1536 px täcker en fotopixel ungefär 1,8 mm av väggen, vilket är vad
    /// en texel i en atlas på 4096 också gör. Höjs bara den ena blir den grövre
    /// av dem taket ändå, och den finare bara dyrare.
    private let targetWidth: CGFloat = 1536

    /// Hur mycket sämre än de tidigare bilderna en bild får vara och ändå
    /// sparas. Vid 0.75 släpps normalt brus igenom men inte en tydlig sudd.
    private let sharpnessFloor = 0.75
    /// Så många bildrutor får letandet efter en skarpare bild ta innan vi
    /// nöjer oss. 5 × 0.2 s ≈ en sekund; längre och kunden hinner vända bort
    /// kameran, och då blir ytan omålad i stället för suddig. Det är sämre.
    private let patience = 5

    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private var timer: Timer?
    private weak var session: ARSession?
    /// Skärpan hos de bilder som sparats, i den ordning de togs. Jämförelsen
    /// måste vara relativ — ett rum med vita väggar har låg kontrast överallt.
    private var recordedSharpness: [Double] = []
    private var skippedFrames = 0

    /// - Parameter maximumCount: fotobudgeten. Tar den slut mitt i skanningen
    ///   saknar resten av rummet bild, och ytorna målas från fel håll.
    ///
    ///   Låg på 40 så länge fotona bara skulle blanda färg per texel — då
    ///   räcker det att varje yta syns i något foto. Splatten ställer en helt
    ///   annan fråga: den ska gå att TITTA på från ett håll ingen fotade, och
    ///   det klarar den bara om fotona ligger tätt. Uppmätt på det riktiga
    ///   rummet, mot fyra undanhållna foton: 9 foton ger felet 0,168, 18 ger
    ///   0,121 och 36 ger 0,102. Kurvan lutar fortfarande vid 36, alltså var
    ///   det taket som band — inte antalet gaussare, inte antalet steg.
    ///
    ///   Kurvan lutade vid 120 också. Skärpan är gaussare per kvadratmeter, och
    ///   antalet gaussare en yta får är i sin tur antalet foton som ser den:
    ///   sexton grannfoton av ETT hörn ger 85 % av fotots skärpa, medan hundraåtta
    ///   foton spridda över hela rummet ger 40 % med lika många gaussare. Inrias
    ///   `train`, som renderas fotorealistiskt i `BenchmarkSplatView`, har 301
    ///   foton av ett enda lok.
    ///
    ///   Taket är alltså vårt, inte skanningens: vid fem bildrutor i sekunden
    ///   erbjuder tre minuters skanning niohundra tillfällen. Kostnaden är
    ///   uppladdningen — knappt en halv megabyte per keyframe med djupet.
    ///
    ///   Därför niohundra: med 3 cm-tröskeln band budgeten vid 297 av 300, så
    ///   det var taket och inte skanningen som avgjorde. Alla andra hävstänger
    ///   är uppmätta och avförda — opacitetsgolv, kulörtak, drift, skärpeviktning
    ///   — medan den här kurvan lutade vid 36 och vid 120 och aldrig har fått
    ///   sluta luta. Priset är en uppladdning på ett par hundra megabyte och en
    ///   träning som växer ungefär i takt med antalet foton.
    init(directory: URL, maximumCount: Int = 900) {
        self.directory = directory
        self.maximumCount = maximumCount
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(session: ARSession) {
        self.session = session
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        session = nil
    }

    // MARK: - Insamling

    private func tick() {
        guard keyframes.count < maximumCount,
              let frame = session?.currentFrame,
              hasMovedEnough(to: frame.camera.transform),
              let rendered = render(frame) else { return }

        guard isSharpEnough(rendered.sharpness) || skippedFrames >= patience else {
            skippedFrames += 1
            return
        }
        skippedFrames = 0
        store(rendered, from: frame)
    }

    /// Sant om bilden håller måttet mot dem som redan sparats. Den första har
    /// inget att jämföras med och släpps alltid igenom.
    private func isSharpEnough(_ value: Double) -> Bool {
        guard !recordedSharpness.isEmpty else { return true }
        let sorted = recordedSharpness.sorted()
        let median = sorted[sorted.count / 2]
        return value >= median * sharpnessFloor
    }

    /// 3 cm eller 8° från den senaste bilden. Under det ser man i praktiken
    /// samma yta från samma håll.
    ///
    /// Låg på 30 cm och 20°, vilket räcker för att blanda färg men inte för att
    /// kunna vrida sig i splatten: mellan två foton som står 20° isär finns inga
    /// mellanliggande vyer att luta sig mot, och splatten fyller mellanrummet
    /// med streck.
    ///
    /// Sedan på 20 cm och 12°, men då band `maximumCount` vid 120 och tröskeln
    /// var aldrig den som avgjorde. Med budgeten på 300 är det tvärtom: tröskeln
    /// är det som bestämmer hur tätt fotona kan ligga, och tätt är hela poängen
    /// — se `maximumCount` för mätningen av vad grannfoton gör med skärpan.
    ///
    /// Talet är därefter satt mot en RIKTIG skanning, inte mot en tänkt: en
    /// användare orkar inte filma i tre minuter, och 12 cm gav då bara 141 foton
    /// av budgetens 300. Nedmätt i steg — 12 cm gav 141, 8 cm 182, 5 cm 213 och
    /// 3 cm 297. Tröskeln ska med andra ord vara så låg att `maximumCount` är
    /// det som binder, annars betalar man för en budget man inte fyller.
    private func hasMovedEnough(to pose: simd_float4x4) -> Bool {
        guard let previous = keyframes.last?.worldFromCamera else { return true }

        let movement = simd_distance(SIMD3(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z),
                                     SIMD3(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z))
        if movement > 0.03 { return true }

        let forward = SIMD3<Float>(-pose.columns.2.x, -pose.columns.2.y, -pose.columns.2.z)
        let previousForward = SIMD3<Float>(-previous.columns.2.x, -previous.columns.2.y, -previous.columns.2.z)
        return simd_dot(forward, previousForward) < cos(8 * .pi / 180)
    }

    /// En färdig bild som ännu inte bestämts vara värd att spara.
    private struct Rendered {
        let jpeg: Data
        let scale: Float
        let size: CGSize
        let sharpness: Double
    }

    private func render(_ frame: ARFrame) -> Rendered? {
        let source = CIImage(cvPixelBuffer: frame.capturedImage)
        let scale = targetWidth / source.extent.width
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let image = context.createCGImage(scaled, from: scaled.extent),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85) else { return nil }

        return Rendered(jpeg: jpeg,
                        scale: Float(scale),
                        size: scaled.extent.size,
                        sharpness: sharpness(of: image))
    }

    private func store(_ rendered: Rendered, from frame: ARFrame) {
        let id = keyframes.count
        let imageURL = directory.appending(path: "kf\(id).jpg")
        guard (try? rendered.jpeg.write(to: imageURL)) != nil else { return }

        let depth = writeDepth(frame, id: id)
        recordedSharpness.append(rendered.sharpness)

        let keyframe = Keyframe(id: id,
                                worldFromCamera: frame.camera.transform,
                                intrinsics: scaledIntrinsics(frame.camera.intrinsics, by: rendered.scale),
                                imageSize: SIMD2(Float(rendered.size.width), Float(rendered.size.height)),
                                depthSize: depth.size)
        keyframes.append(keyframe)
        coverage.add(keyframe, depth: depth.values)
    }

    /// Medelskillnaden mellan grannpixlar i en gråskalekopia. Rörelseoskärpa
    /// jämnar ut den. Samma mått som servern viktar bilderna med, så en bild
    /// som släpps igenom här väger också tungt vid bakningen.
    ///
    /// Kopian är nedskalad — full upplösning kostar mer än den ger, oskärpan
    /// från ett steg i sidled är flera pixlar bred.
    private func sharpness(of image: CGImage) -> Double {
        let width = 384
        let height = max(2, width * image.height / image.width)
        guard let grey = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let base = grey.data else { return 0 }
        grey.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let stride = grey.bytesPerRow
        let pixels = base.bindMemory(to: UInt8.self, capacity: stride * height)
        var total = 0
        for row in 1..<height {
            let line = row * stride
            for column in 1..<width {
                let value = Int(pixels[line + column])
                total += abs(value - Int(pixels[line + column - 1]))
                total += abs(value - Int(pixels[line - stride + column]))
            }
        }
        return Double(total) / Double(2 * (height - 1) * (width - 1))
    }

    /// Brännvidd och bildcentrum skalas med bilden, annars projiceras punkterna
    /// mot en upplösning som inte längre finns.
    private func scaledIntrinsics(_ intrinsics: simd_float3x3, by scale: Float) -> simd_float3x3 {
        var scaled = intrinsics
        scaled.columns.0.x *= scale
        scaled.columns.1.y *= scale
        scaled.columns.2.x *= scale
        scaled.columns.2.y *= scale
        return scaled
    }

    /// LiDAR-djupet, rått Float32. Utan det går ocklusion inte att avgöra och
    /// väggen bakom en spis målas ut över spisen.
    ///
    /// Värdena lämnas tillbaka och inte bara storleken, för täckningskartan
    /// behöver dem med en gång och de är redan uppackade här.
    private func writeDepth(_ frame: ARFrame, id: Int) -> (size: SIMD2<Int32>, values: [Float]) {
        let nothing = (size: SIMD2<Int32>(0, 0), values: [Float]())
        guard let map = frame.sceneDepth?.depthMap ?? frame.smoothedSceneDepth?.depthMap else {
            return nothing
        }

        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }

        let width = CVPixelBufferGetWidth(map)
        let height = CVPixelBufferGetHeight(map)
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nothing }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(map)

        // Raderna kopieras var för sig: `bytesPerRow` är ofta bredare än bilden.
        var values = [Float](repeating: 0, count: width * height)
        values.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                let length = width * MemoryLayout<Float>.size
                destination.baseAddress?.advanced(by: row * length)
                    .copyMemory(from: base.advanced(by: row * bytesPerRow), byteCount: length)
            }
        }

        let data = values.withUnsafeBytes { Data($0) }
        guard (try? data.write(to: directory.appending(path: "kf\(id).depth"))) != nil else {
            return nothing
        }
        return (SIMD2(Int32(width), Int32(height)), values)
    }
}
