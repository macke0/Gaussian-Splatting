//
//  SplatRoomView.swift
//  SpatialFit
//
//  Splatten renderad rakt av, som Polycam gör det.
//
//  Den texturerade meshen kommer alltid att vara mjukare än splatten den målades
//  med: Taubin rundar av kanterna, utglesningen tar bort fyra femtedelar av
//  trianglarna, atlasen tappar en fjärdedel till packning och blandningen
//  medelvärdesbildar bort det fotona är oense om. Här går inget av det förlorat.
//
//  Meshen finns kvar och är den som mäts — det här är bara utseendet.
//

import MetalKit
import MetalSplatter
import SplatIO
import SwiftUI

struct SplatRoomView: UIViewRepresentable {

    let url: URL
    /// Punkten kameran kretsar kring: helst där fotografen stod. Utan den
    /// används mitten av splattens låda, som kan ligga inne i en möbel.
    let standingAt: SIMD3<Float>?
    @Binding var yaw: Float
    @Binding var pitch: Float
    @Binding var distance: Float
    /// Antalet gaussare när de är inne, eller felet som stoppade det.
    let onLoad: @MainActor (Result<Int, Error>) -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // Rått mål, inte `.bgra8Unorm_srgb`. Se `matchingTraining`.
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        // Genomskinlig botten, så gradienten bakom vyn syns där rummet har hål.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.delegate = context.coordinator

        context.coordinator.start(in: view, url: url, standingAt: standingAt, onLoad: onLoad)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setCamera(yaw: yaw, pitch: pitch, distance: distance)
    }

    func makeCoordinator() -> SplatSceneCoordinator {
        SplatSceneCoordinator()
    }
}

/// Hur många gaussare som samlas ihop innan de lämnas till renderaren.
/// PLY-läsaren skickar ut några hundra i taget, och varje klump renderaren
/// håller sorteras om varje bildruta — tusentals små vore dyrare än en stor.
private let chunkSize = 50_000

/// Färgerna som träningen faktiskt passade, inte som shadern gissar att de är.
///
/// gsplat tränar mot fotonas sRGB-pixlar och blandar gaussarna i sRGB.
/// MetalSplatters shader kör i stället varje gaussare genom `pow(2.2)` FÖRE
/// blandningen, för att den räknar med ett `_srgb`-mål som kodar tillbaka
/// efteråt. För en ensam ogenomskinlig gaussare är det samma sak. För femtio
/// halvgenomskinliga staplade på varandra är det inte det: att jämna ut i
/// linjärt rum och koda tillbaka ger ett ljusare och plattare medelvärde än
/// att jämna ut i sRGB. Uppmätt på det här rummet ur appens egen kamera —
/// medelljus 0,55 → 0,63 och skärpa 0,0121 → 0,0100. Det är pastellbilden.
///
/// Shadern går inte att ändra, men den går att mata motsatsen. Lämnar vi in
/// `färg^(1/2.2)` tar dess `pow(2.2)` ut den, och blandningen sker på precis
/// de värden som passades mot fotona. Då måste målet vara rått — kodade det
/// en gång till vore vi tillbaka där vi började.
///
/// Filen på disk rörs inte: den är en vanlig 3DGS-PLY och ska gå att öppna i
/// vilken annan visare som helst.
private func matchingTraining(_ points: [SplatPoint]) -> [SplatPoint] {
    points.map { point in
        var point = point
        let color = point.color.asSRGBFloat
        let compensated = SIMD3(pow(color.x, 1 / 2.2),
                                pow(color.y, 1 / 2.2),
                                pow(color.z, 1 / 2.2))
        point.color = .sphericalHarmonicFloat(
            [(compensated - 0.5) * SplatPoint.Color.INV_SH_C0])
        return point
    }
}

private func bounds(of points: [SplatPoint]) -> (SIMD3<Float>, SIMD3<Float>) {
    guard let first = points.first?.position else { return (.zero, .zero) }

    var low = first, high = first
    for point in points {
        low = simd_min(low, point.position)
        high = simd_max(high, point.position)
    }
    return (low, high)
}

/// Håller renderaren och kameran. `MTKView` ritar om av sig själv, så det här är
/// bara en brevlåda: kamerans läge in, en bild ut.
@MainActor
final class SplatSceneCoordinator: NSObject, MTKViewDelegate {

    private var renderer: SplatRenderer?
    private var queue: MTLCommandQueue?
    private var drawableSize: CGSize = .zero

    /// Punkten kameran kretsar kring. Är fotografens medelpunkt känd står den
    /// fast; annars vandrar den med lådan medan filen läses.
    private var center = SIMD3<Float>(repeating: 0)
    private var anchored = false
    private var lowest: SIMD3<Float>?
    private var highest: SIMD3<Float>?
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance: Float = 6

    /// Synfältet. Samma som `RoomSceneController` använder, så att växlingen
    /// mellan mesh och splat inte hoppar.
    private static let fieldOfView: Float = 60 * .pi / 180

    /// Hur långt ut mot väggen kameran får gå, som andel av vägen dit.
    ///
    /// Meshen går att titta på utifrån — den är en yta och ser likadan ut från
    /// båda hållen. Splatten gör det inte. Den är passad mot foton tagna inne i
    /// rummet, och utanför väggen tittar man på baksidan av ytor som ingen
    /// kamera sett: ett mjölkigt moln med regnbågskanter, vilket är precis vad
    /// vyn visade när kameran ställdes 1,9 rumsradier ut.
    ///
    /// Uppmätt på ett riktigt rum: fotona togs inom 1,5 m från sin egen
    /// medelpunkt medan rummet mäter 3,6 m i radie. Det är alltså bara den
    /// innersta tredjedelen splatten någonsin blivit visad.
    private static let reach: Float = 0.35

    /// Läser filen utanför huvudtråden och lämnar över den bit för bit.
    ///
    /// Två saker gjorde laddningen kännbar. Filen lästes in i sin helhet innan
    /// något ritades, så rummet dök upp först när sista gaussaren var inne. Och
    /// läsningen låg på huvudtråden — hundratusentals punkter avkodade där gör
    /// gränssnittet hackigt precis medan man tittar på det. Nu bygger en egen
    /// tråd klumparna och huvudtråden får dem färdiga.
    func start(in view: MTKView,
               url: URL,
               standingAt viewpoint: SIMD3<Float>?,
               onLoad: @escaping @MainActor (Result<Int, Error>) -> Void) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()

        if let viewpoint {
            center = viewpoint
            anchored = true
        }

        let colorFormat = view.colorPixelFormat
        let depthFormat = view.depthStencilPixelFormat
        let sampleCount = view.sampleCount

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let renderer = try SplatRenderer(device: device,
                                                 colorFormat: colorFormat,
                                                 depthFormat: depthFormat,
                                                 sampleCount: sampleCount,
                                                 maxViewCount: 1,
                                                 maxSimultaneousRenders: 3)
                var pending: [SplatPoint] = []
                var loaded = 0

                for try await batch in try await AutodetectSceneReader(url).read() {
                    pending.append(contentsOf: batch)
                    guard pending.count >= chunkSize else { continue }

                    loaded += pending.count
                    await renderer.addChunk(
                        try SplatChunk(device: device, from: matchingTraining(pending)))
                    await self?.show(renderer, covering: bounds(of: pending))
                    pending.removeAll(keepingCapacity: true)
                }
                if !pending.isEmpty {
                    loaded += pending.count
                    await renderer.addChunk(
                        try SplatChunk(device: device, from: matchingTraining(pending)))
                    await self?.show(renderer, covering: bounds(of: pending))
                }
                await onLoad(.success(loaded))
            } catch {
                await onLoad(.failure(error))
            }
        }
    }

    func setCamera(yaw: Float, pitch: Float, distance: Float) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let renderer, renderer.isReadyToRender,
              let queue, let drawable = view.currentDrawable,
              drawableSize.width > 0, drawableSize.height > 0,
              let commands = queue.makeCommandBuffer() else { return }

        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0,
                                  width: drawableSize.width, height: drawableSize.height,
                                  znear: 0, zfar: 1),
            projectionMatrix: Self.perspective(fieldOfView: Self.fieldOfView,
                                               aspect: Float(drawableSize.width / drawableSize.height)),
            viewMatrix: viewMatrix,
            screenSize: SIMD2(Int(drawableSize.width), Int(drawableSize.height)))

        // Kastar när sorteringen inte hunnit klart. Då hoppar vi över bildrutan
        // hellre än att visa gaussarna i fel ordning.
        guard let rendered = try? renderer.render(viewports: [viewport],
                                                  colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                                  colorStoreAction: view.multisampleColorTexture == nil
                                                      ? .store : .multisampleResolve,
                                                  depthTexture: view.depthStencilTexture,
                                                  rasterizationRateMap: nil,
                                                  renderTargetArrayLength: 0,
                                                  to: commands), rendered else { return }

        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Kameran

    /// Kameran kretsar kring `center`, samma bana som `RoomSceneController`
    /// — men stannar innanför väggarna. Se `reach`.
    private var viewMatrix: simd_float4x4 {
        let direction = SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
        let eye = center + min(distance, reach(along: direction)) * direction
        // Splatten ligger i ARKits värld, Y uppåt. Vanliga 3DGS-filer kommer
        // från COLMAP och står upp och ner — därför vänder MetalSplatters
        // exempelapp på dem. Våra behöver ingen sådan vändning.
        return Self.look(from: eye, at: center, up: SIMD3(0, 1, 0))
    }

    /// Så långt kameran får gå åt ett håll innan den är utanför rummet.
    ///
    /// Rummets låda växer medan filen läses, så gränsen räknas om varje
    /// bildruta i stället för att sparas.
    private func reach(along direction: SIMD3<Float>) -> Float {
        guard let lowest, let highest else { return distance }

        var wall = Float.greatestFiniteMagnitude
        for axis in 0..<3 where abs(direction[axis]) > 1e-5 {
            let side = direction[axis] > 0 ? highest[axis] : lowest[axis]
            wall = min(wall, (side - center[axis]) / direction[axis])
        }
        // Aldrig ända in i mitten: kameran och målpunkten får inte sammanfalla.
        return max(wall * Self.reach, 0.1)
    }

    /// Tar emot en färdig bit: renderaren börjar rita och rummets låda växer.
    ///
    /// Att lådan växer efter hand går bara ihop för att servern skriver filen i
    /// slumpvis ordning — låg gaussarna sorterade skulle mitten vandra genom
    /// hela laddningen och kameran svänga med.
    private func show(_ renderer: SplatRenderer, covering box: (SIMD3<Float>, SIMD3<Float>)) {
        self.renderer = renderer

        let low = simd_min(lowest ?? box.0, box.0)
        let high = simd_max(highest ?? box.1, box.1)
        lowest = low
        highest = high
        if !anchored { center = (low + high) / 2 }
    }

    private static func look(from eye: SIMD3<Float>,
                             at target: SIMD3<Float>,
                             up: SIMD3<Float>) -> simd_float4x4 {
        let backward = normalize(eye - target)
        let right = normalize(cross(up, backward))
        let above = cross(backward, right)

        return simd_float4x4(columns: (
            SIMD4(right.x, above.x, backward.x, 0),
            SIMD4(right.y, above.y, backward.y, 0),
            SIMD4(right.z, above.z, backward.z, 0),
            SIMD4(-dot(right, eye), -dot(above, eye), -dot(backward, eye), 1)))
    }

    /// Högerhänt projektion med djup i 0…1, vilket är vad Metal vill ha.
    private static func perspective(fieldOfView: Float, aspect: Float) -> simd_float4x4 {
        let near: Float = 0.05, far: Float = 100
        let height = 1 / tan(fieldOfView / 2)
        let depth = far / (near - far)

        return simd_float4x4(columns: (
            SIMD4(height / aspect, 0, 0, 0),
            SIMD4(0, height, 0, 0),
            SIMD4(0, 0, depth, -1),
            SIMD4(0, 0, depth * near, 0)))
    }
}
