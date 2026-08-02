//
//  RoomViewerView.swift
//  SpatialFit
//
//  Titta på ett sparat rum i 3D. Kameran kretsar kring rummets mitt och nyp
//  tar dig in i eller ut ur det.
//
//  Rummet visas fotograferat när skanningen hann spara bilder. Den grå mesh:en
//  finns kvar som växelläge — den visar formen utan att fotona döljer var
//  geometrin faktiskt har hål.
//

import SwiftUI
import RealityKit

struct RoomViewerView: View {

    let room: SavedRoom
    let store: RoomStore

    @State private var controller = RoomSceneController()
    @State private var yaw: Float = 0.6
    @State private var pitch: Float = 0.25
    @State private var distance: Float = 6
    @State private var dragStart: SIMD2<Float>?
    @State private var distanceStart: Float?

    @State private var plain: Entity?
    @State private var textured: Entity?
    @State private var showsPhotos = true
    @State private var status: Status = .loading
    @State private var showsProducts = false
    @State private var showsBaking = false

    private enum Status: Equatable {
        case loading
        case texturing
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
                scene
                    .ignoresSafeArea()
                    .gesture(orbitGesture)
                    .simultaneousGesture(zoomGesture)
            }

            if status == .loading || status == .texturing {
                progress
            }
        }
        .overlay(alignment: .bottom) { hint }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if textured != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(showsPhotos ? "Foto" : "Form",
                           systemImage: showsPhotos ? "photo" : "square.grid.3x3") {
                        showsPhotos.toggle()
                        showVariant()
                    }
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
        .sheet(isPresented: $showsBaking) {
            BakeRoomView(room: room, store: store) {
                // Det bakade rummet slår ut det som redan visas.
                textured = try? TexturedMeshEntity.make(in: store.directory(for: room))
                showsPhotos = true
                showVariant()
                status = .ready
            }
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
        VStack(spacing: 10) {
            ProgressView().controlSize(.large)
            if status == .texturing {
                Text("Målar rummet med dina foton…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var hint: some View {
        Group {
            switch status {
            case .plainOnly(let reason):
                Text(reason)
            case .ready where room.nicheCount == 0:
                Text("Inga nischer hittades i rummet.")
            default:
                Text("Dra för att vrida · nyp för att gå in i rummet")
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
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

        // Serverns bakning är gjord med alla foton och blandar dem per texel.
        // Finns den behöver telefonen inte måla om rummet sämre.
        if store.hasBakedRoom(for: room),
           let baked = try? TexturedMeshEntity.make(in: store.directory(for: room)) {
            textured = baked
            showVariant()
            return
        }

        let keyframes = store.keyframes(for: room)
        guard !keyframes.isEmpty else {
            status = .plainOnly("Rummet saknar foton. Skanna om för att måla det.")
            return
        }

        status = .texturing
        do {
            let painted = try await RoomTexturizer.texturize(source: loaded,
                                                            keyframes: keyframes,
                                                            directory: store.directory(for: room))
            textured = painted
            showVariant()
            status = .ready
        } catch {
            status = .plainOnly(error.localizedDescription)
        }
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
