//
//  RoomViewerView.swift
//  SpatialFit
//
//  Titta på ett sparat rum i 3D. Kameran kretsar kring rummets mitt och nyp
//  tar dig in i eller ut ur det.
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

    @State private var loadFailed = false
    @State private var isLoading = true
    @State private var showsProducts = false

    var body: some View {
        ZStack {
            sceneBackground.ignoresSafeArea()

            if loadFailed {
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

            if isLoading {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .bottom) { hint }
        .navigationTitle(room.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        .preferredColorScheme(.dark)
    }

    private var scene: some View {
        RealityView { content in
            content.camera = .virtual
            content.add(controller.root)
            applyCamera()

            do {
                let loaded = try await Entity(contentsOf: store.modelURL(for: room))
                controller.install(loaded)
                distance = controller.defaultDistance
                applyCamera()
            } catch {
                loadFailed = true
            }
            isLoading = false

        } update: { _ in
            applyCamera()
        }
    }

    private var hint: some View {
        Text(room.nicheCount == 0
             ? "Inga nischer hittades i rummet."
             : "Dra för att vrida · nyp för att gå in i rummet")
            .font(.footnote)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 20)
    }

    private var sceneBackground: some View {
        LinearGradient(colors: [Color(red: 0.10, green: 0.11, blue: 0.14),
                                Color(red: 0.03, green: 0.03, blue: 0.05)],
                       startPoint: .top, endPoint: .bottom)
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
