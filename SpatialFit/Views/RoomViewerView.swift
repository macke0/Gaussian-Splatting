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
    @State private var showsSplat = true
    @State private var showsPhotos = true
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
                    if let splat, showsSplat {
                        SplatRoomView(url: splat, yaw: $yaw, pitch: $pitch, distance: $distance) { result in
                            if case .failure = result {
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
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Knapparna heter det de LEDER till, inte det som redan visas. Hette
            // de tvärtom läste man "Splat" som vägen till splatten och tryckte
            // sig bort från den.
            if splat != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showsSplat ? "Visa ytan" : "Visa splatten",
                           systemImage: showsSplat ? "square.grid.3x3" : "sparkles") {
                        showsSplat.toggle()
                    }
                }
            }
            if textured != nil && !showsSplat {
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
                    Text("Splat · dra för att vrida, nyp för att gå in i rummet")
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

    private var sceneBackground: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                Color(red: 0.03, green: 0.03, blue: 0.05)],
                       startPoint: .top, endPoint: .bottom)
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
        guard let variant = showsPhotos ? textured ?? plain : plain else { return }
        controller.install(variant, lit: variant === plain)
        applyCamera()
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
