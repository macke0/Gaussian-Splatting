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
    /// Främmande fil: visa den precis som den är skriven.
    ///
    /// Säger var filen KOMMER IFRÅN, inte hur man tittar på den. Vår tränare
    /// blandar i sRGB och skriver ARKits värld med Y uppåt; en vanlig 3DGS-fil
    /// kommer ur COLMAP, blandar linjärt och står upp och ner. Flaggan styr
    /// därför tre saker som alla följer ursprunget: `matchingTraining`,
    /// målets färgrum, uppvektorn — och percentilramen, som bara behövs när
    /// COLMAP strött enstaka gaussare hundratals meter bort.
    ///
    /// Den finns för att kunna avgöra en enda fråga: renderar vi en känd god fil
    /// skarpt? Gör vi det ligger suddigheten i vår indata och inte i Metal.
    var asAuthored = false
    /// Kretsa fritt kring rummet i stället för att gå i det, även rakt igenom
    /// väggar och möbler.
    ///
    /// Normalt står kameran inne i rummet och stoppas `margin` från närmaste
    /// föremål, se `clearance` — en splat sedd inifrån en soffa är ett taggigt
    /// mörker och inget kunden ska kunna hamna i. Men när vyn används för att
    /// GRANSKA en träningskörning är just baksidorna det man vill se, och då
    /// väger fri rörelse tyngre.
    var roaming = false
    /// Den uppmätta ytan att lägga under splatten, se `BackdropRenderer`.
    ///
    /// Utan den är ett hål i splatten genomsikt rakt ut ur rummet. Med den är
    /// hålet en solid yta som ligger sju millimeter från där splatten skulle ha
    /// legat — oskarpare, men på rätt plats. Det är den som gör att kameran kan
    /// släppas fri utan att rummet ser sönderfallet ut.
    var backdrop: TexturedMesh?
    /// Den bakade atlasen. Saknas den ritas ytan enfärgad.
    var backdropTextureURL: URL?
    /// Vilka lager som ritas. Finns för att kunna se vem av dem som är suddig:
    /// är splatten skarp ensam men rummet smetigt tillsammans ligger felet i
    /// hopfogningen, är den suddig redan ensam ligger det i modellen.
    var layers: Layers = .both
    @Binding var yaw: Float
    @Binding var pitch: Float
    @Binding var distance: Float
    /// Vad som kom in, eller felet som stoppade det.
    let onLoad: @MainActor (Result<Loaded, Error>) -> Void

    /// Splatten som den låg på disk.
    struct Loaded: Sendable {
        let count: Int
        /// SH-graden filen bär. **Noll betyder att rummet är bakat innan
        /// servern började skriva banden** — då är färgen en rest utan glas,
        /// lack eller släpljus, och rummet måste bakas om för att bli skarpt.
        let shDegree: Int
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // Rått mål för våra egna filer, se `matchingTraining` — vi matar in
        // motsatsen till shaderns `pow(2.2)` och då får målet inte koda om en
        // gång till. En främmande fil matas in orörd, och då är shadern rätt
        // som den är: den räknar med ett mål som kodar tillbaka till sRGB.
        view.colorPixelFormat = asAuthored ? .bgra8Unorm_srgb : .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        // Genomskinlig botten, så gradienten bakom vyn syns där rummet har hål.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.isOpaque = false
        view.delegate = context.coordinator

        context.coordinator.start(in: view, url: url, standingAt: standingAt,
                                  asAuthored: asAuthored, roaming: roaming,
                                  backdrop: backdrop, backdropTextureURL: backdropTextureURL,
                                  onLoad: onLoad)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.setCamera(yaw: yaw, pitch: pitch, distance: distance)
        context.coordinator.setLayers(layers)
    }

    func makeCoordinator() -> SplatSceneCoordinator {
        SplatSceneCoordinator()
    }

    /// Splatten, den uppmätta ytan, eller båda.
    enum Layers: String, CaseIterable, Identifiable, Sendable {
        case splats
        case mesh
        case both

        var id: Self { self }

        var label: String {
            switch self {
            case .splats: "Bara splats"
            case .mesh: "Bara yta"
            case .both: "Båda"
            }
        }
    }
}

/// Hur många gaussare som samlas ihop innan de lämnas till renderaren.
/// Läsaren skickar ut några tusen i taget, och varje klump renderaren håller
/// sorteras om varje bildruta — tusentals små vore dyrare än en stor.
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
/// Filen på disk rörs inte: den är en vanlig 3DGS-fil och ska gå att öppna i
/// vilken annan visare som helst.
///
/// **De högre SH-banden MÅSTE följa med.** Den första versionen läste
/// `point.color.asSRGBFloat` — som bara är nolltermen, `0,5 + SH_C0·sh[0]` —
/// och skrev tillbaka EN koefficient. Då blev varje gaussare grad 0, och
/// `SplatChunk` läser graden ur första punkten, så shadern tog sin
/// `SHDegree0`-snabbväg och banden nådde aldrig GPU:n. Det är precis samma fel
/// som `write_spz` hade på servern: optimeraren LÄGGER glas, lack och släpljus
/// i banden, så nolltermen är en rest som aldrig var tänkt att stå ensam.
/// Uppmätt på samma modell är skillnaden mellan full SH och bara nollterm
/// L1 19,16 — sot i taket, dis på väggarna, en parkett utan värme.
private func matchingTraining(_ points: [SplatPoint]) -> [SplatPoint] {
    points.map { point in
        var point = point
        let bands = point.color.asSphericalHarmonicFloat
        // Shaderns egen nollterm, utan `asSRGBFloat`s övre klipp — den kapar
        // högdagrarna innan gammat ens hunnit räknas.
        let base = simd_max(SplatPoint.Color.SH_C0 * bands[0] + 0.5, .zero)
        let compensated = SIMD3(pow(base.x, 1 / 2.2),
                                pow(base.y, 1 / 2.2),
                                pow(base.z, 1 / 2.2))
        var corrected = [(compensated - 0.5) * SplatPoint.Color.INV_SH_C0]

        if bands.count > 1 {
            // Banden är avvikelser KRING nolltermen, och `pow(1/2.2)` trycker
            // ihop skalan olika mycket beroende på hur ljust det är. Rätt
            // storlek i det ihoptryckta rummet är därför derivatan gånger den
            // gamla — kedjeregeln, exakt så länge avvikelsen är liten, vilket
            // den är. Utan skalningen blir riktningsberoendet överdrivet i
            // skuggorna och för svagt i dagrarna.
            let slope = SIMD3(gammaSlope(base.x), gammaSlope(base.y), gammaSlope(base.z))
            for band in bands.dropFirst() { corrected.append(band * slope) }
        }
        point.color = .sphericalHarmonicFloat(corrected)
        return point
    }
}

/// Derivatan av `c^(1/2.2)`, med ett golv på färgen.
///
/// Lutningen växer utan gräns mot svart — vid noll är den oändlig — och
/// linjäriseringen gäller ändå inte där. Två procent ljus kapar den vid knappt
/// fyra, vilket är så mycket riktningsberoende ett nästan svart område kan bära.
private func gammaSlope(_ color: Float) -> Float {
    (1 / 2.2) * pow(max(color, 0.02), 1 / 2.2 - 1)
}

/// Lådan punkterna ligger i, eventuellt med ytterkanterna bortklippta.
///
/// Vår egen splat är klippt redan i träningen och har inga utstickare. En
/// främmande scen har det: COLMAP sätter enstaka gaussare hundratals meter bort
/// där himlen är, och då säger min och max ingenting om var scenen faktiskt är.
/// Med `trimming` blir ramen percentiler i stället, och kameran hittar hem.
///
/// Tiondelen är mätt på Inrias `train`: kärnan är ±2,5 m, men var tjugonde
/// gaussare ligger längre bort än 5 m och var femtionde längre bort än 12.
/// Vid två procent hamnar kameran tjugo meter ut och ser bara bakgrunden.
private func bounds(of points: [SplatPoint],
                    trimming: Float = 0) -> (SIMD3<Float>, SIMD3<Float>) {
    guard let first = points.first?.position else { return (.zero, .zero) }
    guard trimming > 0 else {
        var low = first, high = first
        for point in points {
            low = simd_min(low, point.position)
            high = simd_max(high, point.position)
        }
        return (low, high)
    }

    var low = SIMD3<Float>(), high = SIMD3<Float>()
    let cut = Int(Float(points.count) * trimming)
    for axis in 0..<3 {
        let sorted = points.map { $0.position[axis] }.sorted()
        low[axis] = sorted[cut]
        high[axis] = sorted[sorted.count - 1 - cut]
    }
    return (low, high)
}

/// Kantlängden på beläggningskartans kuber.
///
/// Grovt med flit. Kartan ska svara på "är det något här", inte beskriva formen,
/// och femton centimeter är mindre än marginalen kameran ändå hålls på avstånd.
private let cellSize: Float = 0.15

/// Hur ogenomskinlig en gaussare måste vara för att räknas som ett föremål.
/// De genomskinliga är dis, gardiner och glas — kameran ska få gå fram till ett
/// fönster utan att stoppas av rutan.
private let solidEnough: Float = 0.3

/// Kuben en punkt ligger i, packad i ett tal.
///
/// Tjugoen bitar per led räcker för ±150 km, och rummet är åtta meter.
private func cell(containing point: SIMD3<Float>) -> Int64 {
    let index = SIMD3<Int64>(floor(point / cellSize)) &+ SIMD3<Int64>(repeating: 1 << 20)
    return index.x << 42 | index.y << 21 | index.z
}

/// Kuberna de här gaussarna fyller.
///
/// Räknas utanför huvudtråden: ett par miljoner punkter hashade där hade synts
/// som hack precis medan man tittar på rummet växa fram.
private func occupancy(of points: [SplatPoint]) -> Set<Int64> {
    var cells = Set<Int64>()
    for point in points where point.opacity.asLinearFloat >= solidEnough {
        cells.insert(cell(containing: point.position))
    }
    return cells
}

/// Håller renderaren och kameran. `MTKView` ritar om av sig själv, så det här är
/// bara en brevlåda: kamerans läge in, en bild ut.
@MainActor
final class SplatSceneCoordinator: NSObject, MTKViewDelegate {

    private var renderer: SplatRenderer?
    /// Den uppmätta ytan under splatten. `nil` när rummet saknar mesh eller
    /// enheten inte kunde bygga rörledningarna.
    private var backdrop: BackdropRenderer?
    private var queue: MTLCommandQueue?
    private var drawableSize: CGSize = .zero

    /// Punkten kameran kretsar kring när den kretsar. Är fotografens medelpunkt
    /// känd står den fast; annars vandrar den med lådan medan filen läses.
    private var center = SIMD3<Float>(repeating: 0)
    private var anchored = false
    /// Var kameran står när den går. Startar där fotografen stod, vilket är fri
    /// luft per definition — någon har gått där.
    private var eye = SIMD3<Float>(repeating: 0)
    /// Se `SplatRoomView.asAuthored` och `.roaming`.
    private var asAuthored = false
    private var roaming = false
    /// Se `SplatRoomView.layers`.
    private var layers: SplatRoomView.Layers = .both
    private var lowest: SIMD3<Float>?
    private var highest: SIMD3<Float>?
    /// Var det står något. Växer medan filen läses, se `occupancy`.
    private var occupied = Set<Int64>()
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var distance: Float = 6

    /// Synfältet. Samma som `RoomSceneController` använder, så att växlingen
    /// mellan mesh och splat inte hoppar.
    private static let fieldOfView: Float = 60 * .pi / 180

    /// Hur långt bort `clearance` letar efter föremål, i meter.
    ///
    /// Talet är mätt: under skanningen höll telefonen 0,86 m till närmaste yta
    /// som median och 0,56 m som tiondepercentil, och bara 0,7 % av de 267
    /// fotona togs närmare än 30 cm. Närmare än så finns alltså inget foto att
    /// luta sig mot, och det var det som gjorde den gamla kretsande banan
    /// trasig: 20,6 % av lägena den kunde nå låg innanför tre decimeter.
    ///
    /// Men avståndet är inte längre en SPÄRR, bara en skala att jämföra lägen
    /// med. Se `walk`.
    private static let margin: Float = 0.4

    /// Hur långt utanför rummets låda kameran får backa, i meter.
    ///
    /// Att kunna dra sig ut och se rummet uppifrån är halva behållningen, och
    /// med den uppmätta ytan bakom splatten finns det något att se därifrån.
    /// Taket är kvar för att en splat sedd från andra sidan gatan bara är ett
    /// moln — och för att man ska hitta tillbaka in.
    private static let reach: Float = 2.5

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
               asAuthored: Bool = false,
               roaming: Bool = false,
               backdrop: TexturedMesh? = nil,
               backdropTextureURL: URL? = nil,
               onLoad: @escaping @MainActor (Result<SplatRoomView.Loaded, Error>) -> Void) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        self.asAuthored = asAuthored
        self.roaming = roaming

        if let backdrop {
            self.backdrop = BackdropRenderer(device: device,
                                             colorFormat: view.colorPixelFormat,
                                             depthFormat: view.depthStencilPixelFormat)
            self.backdrop?.load(backdrop, textureURL: backdropTextureURL)
        }

        if let viewpoint {
            center = viewpoint
            eye = viewpoint
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
                // Graden filen bär. Läses ur punkterna som de kom, innan
                // `matchingTraining` rört dem.
                var degree = 0

                for try await batch in try await AutodetectSceneReader(url).read() {
                    pending.append(contentsOf: batch)
                    guard pending.count >= chunkSize else { continue }

                    loaded += pending.count
                    degree = max(degree, Int(pending[0].color.shDegree.rawValue))
                    await renderer.addChunk(try SplatChunk(
                        device: device,
                        from: asAuthored ? pending : matchingTraining(pending)))
                    await self?.show(renderer,
                                     covering: bounds(of: pending,
                                                      trimming: asAuthored ? 0.1 : 0),
                                     filling: roaming ? [] : occupancy(of: pending))
                    pending.removeAll(keepingCapacity: true)
                }
                if !pending.isEmpty {
                    loaded += pending.count
                    degree = max(degree, Int(pending[0].color.shDegree.rawValue))
                    await renderer.addChunk(try SplatChunk(
                        device: device,
                        from: asAuthored ? pending : matchingTraining(pending)))
                    await self?.show(renderer,
                                     covering: bounds(of: pending,
                                                      trimming: asAuthored ? 0.1 : 0),
                                     filling: roaming ? [] : occupancy(of: pending))
                }
                await onLoad(.success(.init(count: loaded, shDegree: degree)))
            } catch {
                await onLoad(.failure(error))
            }
        }
    }

    func setCamera(yaw: Float, pitch: Float, distance: Float) {
        self.yaw = yaw
        self.pitch = pitch
        // Kretsar kameran är `distance` var den står. Går den är avståndet i
        // stället en ratt: det den ÄNDRAS med blir steg framåt längs blicken.
        if !orbiting { walk(self.distance - distance) }
        self.distance = distance
    }

    func setLayers(_ layers: SplatRoomView.Layers) {
        self.layers = layers
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let renderer, renderer.isReadyToRender,
              let queue, let drawable = view.currentDrawable,
              drawableSize.width > 0, drawableSize.height > 0,
              let commands = queue.makeCommandBuffer() else { return }

        let projection = Self.perspective(fieldOfView: Self.fieldOfView,
                                          aspect: Float(drawableSize.width / drawableSize.height))
        let view32 = viewMatrix
        let viewport = SplatRenderer.ViewportDescriptor(
            viewport: MTLViewport(originX: 0, originY: 0,
                                  width: drawableSize.width, height: drawableSize.height,
                                  znear: 0, zfar: 1),
            projectionMatrix: projection,
            viewMatrix: view32,
            screenSize: SIMD2(Int(drawableSize.width), Int(drawableSize.height)))

        // Med bakgrund ritas rummet i tre steg: ytan i bilden, splatten i en
        // egen ruta, och ruta över bild. Utan bakgrund går splatten rakt in i
        // bilden som förr — MetalSplatter rensar den ändå.
        let usesBackdrop = layers != .splats && backdrop?.isReady == true
        let target = usesBackdrop
            ? backdrop?.splatTarget(size: drawableSize, format: view.colorPixelFormat)
            : nil
        // Ingen yta att visa och splatten avstängd: låt förra bildrutan stå
        // kvar hellre än att visa en orensad ruta.
        guard layers != .mesh || usesBackdrop else { return }

        if usesBackdrop, let backdrop {
            backdrop.drawMesh(into: commands,
                              color: view.multisampleColorTexture ?? drawable.texture,
                              depth: view.depthStencilTexture,
                              viewProjection: projection * view32,
                              eye: cameraPosition)
        }

        if layers != .mesh {
            // Kastar när sorteringen inte hunnit klart. Då hoppar vi över
            // bildrutan hellre än att visa gaussarna i fel ordning.
            guard let rendered = try? renderer.render(
                viewports: [viewport],
                colorTexture: target ?? view.multisampleColorTexture ?? drawable.texture,
                colorStoreAction: target != nil || view.multisampleColorTexture == nil
                    ? .store : .multisampleResolve,
                depthTexture: view.depthStencilTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commands), rendered else { return }

            if let backdrop, let target {
                backdrop.composite(target, into: commands,
                                   color: view.multisampleColorTexture ?? drawable.texture,
                                   storeAction: view.multisampleColorTexture == nil
                                       ? .store : .multisampleResolve)
            }
        }

        commands.present(drawable)
        commands.commit()
    }

    // MARK: - Kameran

    /// Riktningen blicken pekar åt, ur `yaw` och `pitch`.
    private var heading: SIMD3<Float> {
        -SIMD3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
    }

    /// Var kameran står, oavsett om den kretsar eller går.
    private var cameraPosition: SIMD3<Float> {
        orbiting ? center - range * heading : eye
    }

    /// Vår egen splat ses INIFRÅN: kameran står i rummet och blicken svänger.
    /// En främmande fil kretsar som förr — den är oftast ett föremål man ska gå
    /// runt, och `BenchmarkSplatView` jämför träningskörningar ur samma bana.
    private var viewMatrix: simd_float4x4 {
        // Splatten ligger i ARKits värld, Y uppåt. Vanliga 3DGS-filer kommer
        // från COLMAP och står upp och ner — därför vänder MetalSplatters
        // exempelapp på dem, och därför vänder vi en främmande fil men inte vår.
        guard !orbiting else {
            let eye = center - range * heading
            return Self.look(from: eye, at: center,
                             up: SIMD3(0, asAuthored ? -1 : 1, 0))
        }
        return Self.look(from: eye, at: eye + heading, up: SIMD3(0, 1, 0))
    }

    /// Kretsar kameran kring en punkt i stället för att stå i rummet?
    private var orbiting: Bool { asAuthored || roaming }

    /// Hur långt ut kameran ställs när den kretsar.
    ///
    /// En främmande fil har varken kända väggar eller känd skala: COLMAP väljer
    /// sin enhet fritt. Utan given målpunkt räknas `distance` därför i
    /// scenradier, så att samma startvärde ramar in vad som helst. Är målpunkten
    /// given kommer den ur datasetets egna kameror, och då är skalan känd igen.
    private var range: Float {
        asAuthored && !anchored ? distance * radius : distance
    }

    /// Halva scenens längsta sida, aldrig noll.
    private var radius: Float {
        guard let lowest, let highest else { return 1 }
        return max((highest - lowest).max() / 2, 0.001)
    }

    /// Flyttar kameran framåt eller bakåt, om den får plats där.
    ///
    /// Zoom är gång: `distance` minskar när man nyper isär, och då går kameran
    /// framåt längs blicken. Att i stället kretsa kring en fast punkt var det som
    /// gjorde rummet trasigt att vrida i. Uppmätt låg **20,6 % av de lägen den
    /// gamla banan kunde nå närmare än 30 cm från en yta, mot 0,7 % av fotona** —
    /// kameran svepte rakt genom soffan, och inifrån en soffa har ingen
    /// fotograferat. Det såg ut som trasig geometri men var en trasig kamerabana.
    ///
    /// Med spärren finns 106 m³ att gå i och 7,3 m tvärs rummet. Med den fasta
    /// punkten kvar hade det blivit 10 cm: nästan varje håll är blockerat på
    /// nära håll, och det är därför den gamla vyn bara dög från vissa vinklar.
    ///
    /// Spärren låg först på fyra decimeter, för då var ett hål i splatten
    /// genomsikt rakt ut ur rummet och allt nära såg sönderfallet ut. Med den
    /// uppmätta ytan bakom splatten — se `BackdropRenderer` — finns alltid något
    /// solidt att titta på, och då är det bara att gå IN i en möbel som är
    /// meningslöst. Kvar är därför ett enda kubsteg, femton centimeter: nära nog
    /// att sätta näsan mot bänkskivan, långt nog att inte hamna inuti den.
    private func walk(_ steps: Float) {
        guard steps != 0 else { return }
        let target = eye + steps * heading
        guard inside(target) else { return }

        // Inte bara "är målet fritt" utan också "är målet minst lika fritt".
        // Uppmätt ligger fotografens medelpunkt — den vi STARTAR i — själv tätt
        // intill en yta, och med en ren ja/nej-spärr satt kameran fast direkt vid
        // start. Den här regeln släpper ut ur ett trångt läge men aldrig in i ett
        // trängre.
        let room = clearance(at: target)
        guard room >= 1 || room >= clearance(at: eye) else { return }
        eye = target
    }

    /// Är punkten innanför rummets låda, plus `reach`?
    ///
    /// Väggarna är gaussare och fångas av `clearance`. Lådan behövs ändå: genom
    /// ett fönster eller en öppen dörr finns inga gaussare alls, och utan den
    /// här spärren skulle kameran gå iväg tills rummet var en prick.
    private func inside(_ point: SIMD3<Float>) -> Bool {
        guard let lowest, let highest else { return true }
        let slack = SIMD3<Float>(repeating: Self.reach)
        return all(point .>= lowest - slack) && all(point .<= highest + slack)
    }

    /// Hur många kubsteg det är till närmaste föremål, som mest `margin`.
    ///
    /// Ett tal och inte ett ja/nej, för att `walk` ska kunna jämföra två lägen.
    /// Alla punkter med minst `margin` fritt runt sig får samma toppvärde, så
    /// kameran rör sig obehindrat i det öppna rummet och märker spärren först
    /// när den närmar sig något.
    ///
    /// Kuberna runt punkten söks av i stället för att kartan utvidgas en gång:
    /// utvidgningen hade kostat en dryg miljon insättningar under inläsningen,
    /// och det här är ett par hundra uppslagningar bara när någon faktiskt går.
    private func clearance(at point: SIMD3<Float>) -> Int {
        let reach = Int(ceil(Self.margin / cellSize))
        guard !occupied.isEmpty else { return reach }
        guard !occupied.contains(cell(containing: point)) else { return 0 }

        for step in 1...reach {
            for x in -step...step {
                for y in -step...step {
                    for z in -step...step where max(abs(x), max(abs(y), abs(z))) == step {
                        let offset = SIMD3(Float(x), Float(y), Float(z)) * cellSize
                        if occupied.contains(cell(containing: point + offset)) {
                            return step - 1
                        }
                    }
                }
            }
        }
        return reach
    }

    /// Tar emot en färdig bit: renderaren börjar rita och rummets låda växer.
    ///
    /// Att lådan växer efter hand går bara ihop för att servern skriver filen i
    /// slumpvis ordning — låg gaussarna sorterade skulle mitten vandra genom
    /// hela laddningen och kameran svänga med.
    private func show(_ renderer: SplatRenderer,
                      covering box: (SIMD3<Float>, SIMD3<Float>),
                      filling cells: Set<Int64>) {
        self.renderer = renderer
        occupied.formUnion(cells)

        let low = simd_min(lowest ?? box.0, box.0)
        let high = simd_max(highest ?? box.1, box.1)
        lowest = low
        highest = high
        // Utan fotografens medelpunkt finns inget bättre än lådans mitt. Den kan
        // ligga i en möbel — därför är `standingAt` att föredra, se
        // `RoomViewerView.viewpoint`.
        if !anchored {
            center = (low + high) / 2
            eye = center
        }
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
