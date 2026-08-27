//
//  RoomViewerView.swift
//  SpatialFit
//
//  Titta på ett sparat rum i 3D. Kameran kretsar kring rummets mitt och nyp
//  tar dig in i eller ut ur det.
//
//  Rummet visas fotograferat först när det är bakat på server. Dessförinnan
//  visas den grå mesh:en, som ändå är den som säger sanningen om formen: fotona
//  döljer var geometrin har hål.
//

import SwiftUI
import RealityKit

struct RoomViewerView: View {

    let room: SavedRoom
    let store: RoomStore
    let queue: BakeQueue

    @State private var controller = RoomSceneController()
    @State private var yaw: Float = 0.6
    @State private var pitch: Float = 0.25
    @State private var distance: Float = 6
    @State private var dragStart: SIMD2<Float>?
    @State private var distanceStart: Float?

    @State private var plain: Entity?
    /// Den bakade ytan från servern, när rummet har en.
    @State private var textured: Entity?
    /// Splatten från servern. Den är utseendet; meshen är måtten.
    @State private var splat: URL?
    /// Samma yta färgad efter hur väl skanningen täckte den. Räknas fram först
    /// när kunden ber om den — mätningen läser in alla djupkartor.
    @State private var coverage: Entity?
    @State private var coverageReport: SurfaceCoverage.Report?
    @State private var showsCoverage = false
    @State private var measuringCoverage = false
    @State private var showsSplat = true
    @State private var showsPhotos = true
    /// Vilka lager splatvyn ritar. Ett felsökningsreglage: syns smetet redan i
    /// "Bara splats" sitter det i modellen, syns det först i "Båda" sitter det i
    /// hopfogningen med den uppmätta ytan.
    @State private var splatLayers: SplatRoomView.Layers = .both
    /// Den uppmätta ytan bakom splatten, se `loadBackdrop`.
    @State private var backdrop: TexturedMesh?
    @State private var backdropTextureURL: URL?
    /// SH-graden splatfilen bär. Noll betyder att den är bakad innan servern
    /// började skriva banden, och då kan den inte bli skarp hur den än ritas.
    @State private var splatDegree: Int?
    @State private var status: Status = .loading
    @State private var showsProducts = false
    @State private var showsBaking = false
    @State private var showsContents = false

    private enum Status: Equatable {
        case loading
        case ready
        /// Geometrin gick att visa men fotona inte att måla med.
        case plainOnly(String)
        case failed
    }

    var body: some View {
        ZStack {
            sceneBackground.ignoresSafeArea()

            if status == .failed {
                ContentUnavailableView {
                    Label("Kunde inte öppna rummet", systemImage: "cube.transparent")
                } description: {
                    Text("3D-modellen saknas eller gick inte att läsa. Skanna rummet igen.")
                }
            } else {
                Group {
                    // Täckningen ritas på mesh:en, inte på splatten. Poängen är
                    // att se var mätningen SAKNAS, och splatten fyller hålen med
                    // gissningar — det är just det som gör dem svåra att se.
                    if let splat, showsSplat, !showsCoverage {
                        SplatRoomView(url: splat, standingAt: viewpoint,
                                      backdrop: backdrop,
                                      backdropTextureURL: backdropTextureURL,
                                      layers: splatLayers,
                                      yaw: $yaw, pitch: $pitch, distance: $distance) { result in
                            switch result {
                            case .success(let loaded):
                                splatDegree = loaded.shDegree
                            case .failure:
                                // Meshen finns kvar och duger. Att falla tillbaka
                                // tyst är fel — vyn ska säga vad du tittar på.
                                self.splat = nil
                                status = .plainOnly("Splatten gick inte att läsa. Visar den bakade ytan.")
                            }
                        }
                        .id(splat)
                    } else {
                        scene
                    }
                }
                .ignoresSafeArea()
                .gesture(orbitGesture)
                .simultaneousGesture(zoomGesture)
            }

            if status == .loading {
                progress
            }
        }
        .overlay(alignment: .bottom) { hint }
        .overlay(alignment: .top) { layerPicker }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Knapparna heter det de LEDER till, inte det som redan visas. Hette
            // de tvärtom läste man "Splat" som vägen till splatten och tryckte
            // sig bort från den.
            ToolbarItem(placement: .topBarTrailing) {
                Button(showsCoverage ? "Visa rummet" : "Täckning",
                       systemImage: showsCoverage ? "cube" : "circle.lefthalf.filled") {
                    if showsCoverage {
                        showsCoverage = false
                        showVariant()
                    } else {
                        Task { await showCoverage() }
                    }
                }
                .disabled(measuringCoverage)
            }
            if splat != nil && !showsCoverage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showsSplat ? "Visa ytan" : "Visa splatten",
                           systemImage: showsSplat ? "square.grid.3x3" : "sparkles") {
                        showsSplat.toggle()
                    }
                }
            }
            if textured != nil && !showsSplat && !showsCoverage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showsPhotos ? "Visa formen" : "Visa fotona",
                           systemImage: showsPhotos ? "square.grid.3x3" : "photo") {
                        showsPhotos.toggle()
                        showVariant()
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("I rummet", systemImage: "list.bullet.rectangle") {
                    showsContents = true
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Baka rummet", systemImage: "paintbrush") {
                    showsBaking = true
                }
                .disabled(!room.hasPhotos)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Lägg till produkt", systemImage: "shippingbox") {
                    showsProducts = true
                }
                .disabled(room.nicheCount == 0)
            }
        }
        .fullScreenCover(isPresented: $showsProducts) {
            ProductPlacementView(room: room, store: store)
        }
        .sheet(isPresented: $showsContents) {
            RoomContentsView(room: room, store: store)
        }
        .sheet(isPresented: $showsBaking) {
            BakeRoomView(room: room, store: store, queue: queue)
        }
        .onChange(of: queue.phase(for: room)) { _, phase in
            // Bakningen kan bli klar när som helst, också långt efter att arket
            // stängdes. Det målade rummet slår ut det som redan visas.
            guard case .done = phase else { return }
            textured = try? TexturedMeshEntity.make(in: store.directory(for: room))
            splat = store.splatURL(for: room)
            loadBackdrop()
            showsPhotos = true
            showsSplat = true
            showVariant()
            status = .ready
        }
        .preferredColorScheme(.dark)
    }

    private var scene: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(controller.root)
            applyCamera()
            await load()

        } update: { _ in
            applyCamera()
        }
    }

    /// Väljer vilka lager splatvyn ritar. Syns bara när det finns två lager att
    /// välja mellan — utan uppmätt yta finns inget att jämföra med.
    @ViewBuilder
    private var layerPicker: some View {
        if splat != nil, showsSplat, !showsCoverage, backdrop != nil {
            Picker("Lager", selection: $splatLayers) {
                ForEach(SplatRoomView.Layers.allCases) { layer in
                    Text(layer.label).tag(layer)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
            .padding(.horizontal, 24)
            .padding(.top, 8)
        }
    }

    private var progress: some View {
        ProgressView()
            .controlSize(.large)
            .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// Nedersta raden säger vad du tittar på. Går en bakning tar den platsen —
    /// den är det enda som ändrar sig av sig självt medan rummet står stilla.
    @ViewBuilder
    private var hint: some View {
        if measuringCoverage {
            HStack(spacing: 10) {
                ProgressView()
                Text("Mäter täckningen…")
            }
            .bottomCaption()
        } else if showsCoverage, let coverageReport {
            coverageLegend(coverageReport)
        } else {
            bakeHint
        }
    }

    /// Teckenförklaringen ÄR svaret på frågan, inte en not till den: talen säger
    /// hur mycket som är kvar och färgerna var det sitter.
    private func coverageLegend(_ report: SurfaceCoverage.Report) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                swatch(.solid, "Uppmätt", report.solidFraction)
                swatch(.thin, "Ett håll", report.thinFraction)
                swatch(.missing, "Saknas", report.missingFraction)
            }
            Text(report.missingFraction + report.thinFraction < 0.1
                 ? "Rummet är väl täckt."
                 : "Gå tillbaka till det gula och röda och filma därifrån — helst runt föremålen, inte förbi dem.")
                .foregroundStyle(.secondary)
        }
        .bottomCaption()
    }

    private func swatch(_ level: SurfaceCoverage.Level,
                        _ label: String,
                        _ fraction: Double) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color(level))
                .frame(width: 9, height: 9)
            Text("\(label) \(Int((fraction * 100).rounded())) %")
        }
    }

    @ViewBuilder
    private var bakeHint: some View {
        switch queue.phase(for: room) {
        case .working(let message):
            HStack(spacing: 10) {
                ProgressView()
                Text(message)
            }
            .bottomCaption()
        case .failed(let reason):
            Text(reason)
                .foregroundStyle(.orange)
                .bottomCaption()
        default:
            Group {
                switch status {
                case .plainOnly(let reason):
                    Text(reason)
                case .ready where splat != nil && showsSplat:
                    // Splatvyn kan inte lämna rummet — den stämmer bara
                    // inifrån. Se `SplatRoomView.reach`.
                    splatHint
                case .ready where splat != nil:
                    // Den bakade ytan är alltid mjukare än splatten som målade
                    // den. Ligger en splat på disk ska ingen tro att smetet är
                    // det bästa telefonen kan.
                    Text("Bakad yta · tryck Visa splatten för den skarpa bilden")
                case .ready where room.nicheCount == 0:
                    Text("Inga nischer hittades i rummet.")
                default:
                    Text("Dra för att vrida · nyp för att gå in i rummet")
                }
            }
            .bottomCaption()
        }
    }

    /// Raden under splatten. Graden står ALLTID utskriven.
    ///
    /// Första versionen varnade bara vid grad 0 och teg annars. Men `splatDegree`
    /// är `nil` tills filen är läst, och tyst-vid-noll är omöjligt att skilja
    /// från tyst-för-att-allt-är-bra — man får en avläsning som inte går att
    /// läsa. Ett tal som står där svarar på frågan direkt.
    @ViewBuilder
    private var splatHint: some View {
        switch splatDegree {
        case nil:
            Text("Splat · läser…")
        case 0:
            // Utan de högre banden är färgen en REST: optimeraren la glas, lack
            // och släpljus där, och nolltermen ensam ger sot i taket och dis på
            // väggarna. Det går inte att rita bort.
            Text("Splat · SH-grad 0 — saknar riktningsberoende färg. Baka om rummet för den skarpa bilden.")
                .foregroundStyle(.orange)
        case let degree?:
            Text("Splat · SH-grad \(degree) · dra för att se dig omkring, nyp för att komma närmare")
        }
    }

    private var sceneBackground: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                Color(red: 0.03, green: 0.03, blue: 0.05)],
                       startPoint: .top, endPoint: .bottom)
    }

    // MARK: - Ytan under splatten

    /// Den uppmätta ytan att lägga bakom splatten.
    ///
    /// Den bakade atlasen först — den har fotonas färger. Finns den inte duger
    /// den råa LiDAR-ytan enfärgad; poängen är att hålen i splatten ska ha
    /// NÅGOT bakom sig, och en solid grå vägg på rätt plats slår genomsikt.
    ///
    /// Läses EN gång, i `load`. `body` körs om vid varje dragrörelse, och att
    /// avkoda ett par hundra tusen hörn från disk däri gör vyn ospelbar.
    private static func loadBackdrop(from folder: URL, store: RoomStore,
                                     room: SavedRoom) -> TexturedMesh? {
        if let data = try? Data(contentsOf: folder.appending(path: TexturedMesh.meshFilename)),
           let baked = TexturedMesh(data: data) {
            return baked
        }
        guard let mesh = store.sceneMesh(for: room), !mesh.isEmpty else { return nil }
        // Utan atlas används aldrig texturkoordinaterna, men rörledningen läser
        // en per hörn — därför nollor och inte en tom lista.
        return TexturedMesh(positions: mesh.positions,
                            normals: mesh.vertexNormals(),
                            textureCoordinates: Array(repeating: .zero, count: mesh.positions.count),
                            indices: mesh.indices)
    }

    private func loadBackdrop() {
        let folder = store.directory(for: room)
        backdrop = Self.loadBackdrop(from: folder, store: store, room: room)
        let texture = folder.appending(path: TexturedMesh.textureFilename)
        backdropTextureURL = FileManager.default.fileExists(atPath: texture.path) ? texture : nil
    }

    // MARK: - Laddning

    /// Geometrin visas direkt. Textureringen tar sekunder och får komma efter,
    /// så att rummet syns medan den räknas.
    private func load() async {
        guard plain == nil else { return }

        guard let loaded = await geometry() else {
            status = .failed
            return
        }
        plain = loaded
        controller.install(loaded)
        distance = controller.defaultDistance
        applyCamera()
        status = .ready

        // Splatten går före allt annat när den finns: den är den enda ytan som
        // inte gått genom utjämning, utglesning och en atlas på vägen hit.
        splat = store.splatURL(for: room)
        loadBackdrop()

        // Serverns bakning är gjord med alla foton och blandar dem per texel.
        // Finns den behöver telefonen inte måla om rummet sämre.
        if store.hasBakedRoom(for: room),
           let baked = try? TexturedMeshEntity.make(in: store.directory(for: room)) {
            textured = baked
            showVariant()
            return
        }
        if splat != nil { return }

        guard !store.keyframes(for: room).isEmpty else {
            status = .plainOnly("Rummet saknar foton. Skanna om för att måla det.")
            return
        }

        // Lapptäcket målades förr här, automatiskt. Det gav intrycket att appen
        // var trasig: ett foto per triangel gör rummet till utspridda skärvor ur
        // olika bilder, och den som ser det tror att geometrin är sönder. Den
        // bakade ytan är mätt mot fotona och återger rummet — se `Texturing/`.
        // Hellre grå form än en bild som ljuger om vad som gick fel.
        status = .plainOnly("Rummet är inte bakat. Tryck Baka rummet för att måla det med dina foton.")
    }

    /// Punkten splatvyn kretsar kring: medelpunkten för de foton den tränats på.
    ///
    /// Mitten av splattens låda duger inte. Den är ett medelvärde av väggarna,
    /// och i ett rum som inte är rätblockigt hamnar den var som helst — uppmätt
    /// på användarens rum 18 cm från närmaste yta, alltså inne i en möbel. Där
    /// står kameran och tittar rakt in i något på decimeterhåll.
    ///
    /// Fotografens egen medelpunkt är fri luft per definition: någon har gått
    /// där. Samma rum, 75 cm till närmaste gaussare.
    private var viewpoint: SIMD3<Float>? {
        let eyes = store.keyframes(for: room).map { keyframe in
            SIMD3(keyframe.worldFromCamera.columns.3.x,
                  keyframe.worldFromCamera.columns.3.y,
                  keyframe.worldFromCamera.columns.3.z)
        }
        guard !eyes.isEmpty else { return nil }
        return eyes.reduce(.zero, +) / Float(eyes.count)
    }

    /// Den täta LiDAR-ytan först: den har möblernas verkliga former. RoomPlans
    /// export är lådor och plan, och används bara när skanningen är gjord innan
    /// ytan sparades — eller på en enhet utan scenrekonstruktion.
    private func geometry() async -> Entity? {
        if let mesh = store.sceneMesh(for: room), let entity = SceneMeshEntity.make(from: mesh) {
            return entity
        }
        return try? await Entity(contentsOf: store.modelURL(for: room))
    }

    private func showVariant() {
        // `lit: false` betyder bara att scenen inte skriver över materialen —
        // täckningsfärgerna måste överleva. De belyses ändå av scenens ljus, så
        // att formen syns och man ser var i rummet det röda sitter.
        if showsCoverage, let coverage {
            controller.install(coverage, lit: false)
            applyCamera()
            return
        }
        guard let variant = showsPhotos ? textured ?? plain : plain else { return }
        controller.install(variant, lit: variant === plain)
        applyCamera()
    }

    // MARK: - Täckning

    /// Räknar fram täckningen en gång och visar den.
    ///
    /// Mätningen läser in alla djupkartor — ett par hundra på tiotals megabyte —
    /// och projicerar varje hörn mot varje foto. Den görs därför på begäran och
    /// utanför huvudtråden, och resultatet sparas så att knappen blir omedelbar
    /// andra gången.
    private func showCoverage() async {
        if coverage != nil {
            showsCoverage = true
            showVariant()
            return
        }
        guard let mesh = store.sceneMesh(for: room) else {
            status = .plainOnly("Rummet saknar uppmätt yta, så täckningen går inte att visa.")
            return
        }
        let keyframes = store.keyframes(for: room)
        guard !keyframes.isEmpty else {
            status = .plainOnly("Rummet saknar foton, så täckningen går inte att visa.")
            return
        }

        let folder = store.directory(for: room)
        measuringCoverage = true
        let report = await Task.detached(priority: .userInitiated) {
            let depth = DepthMaps(keyframes: keyframes, directory: folder)
            return SurfaceCoverage.measure(mesh: mesh, keyframes: keyframes, depth: depth.lookup)
        }.value
        measuringCoverage = false

        guard let entity = CoverageMeshEntity.make(from: mesh, report: report) else {
            status = .plainOnly("Täckningen gick inte att rita.")
            return
        }
        coverageReport = report
        coverage = entity
        showsCoverage = true
        showVariant()
    }

    // MARK: - Gester

    private var orbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? SIMD2(yaw, pitch)
                if dragStart == nil { dragStart = start }
                yaw = start.x - Float(value.translation.width) * 0.008
                pitch = start.y + Float(value.translation.height) * 0.006
                applyCamera()
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = distanceStart ?? distance
                if distanceStart == nil { distanceStart = base }
                distance = min(max(base / Float(value.magnification),
                                   controller.minimumDistance),
                               controller.maximumDistance)
                applyCamera()
            }
            .onEnded { _ in distanceStart = nil }
    }

    private func applyCamera() {
        controller.setCamera(yaw: yaw, pitch: pitch, distance: distance)
    }
}

private extension View {
    /// Kapseln nertill. Matt botten, så texten går att läsa mot både en vit vägg
    /// och ett mörkt hörn.
    func bottomCaption() -> some View {
        font(.footnote)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
    }
}
