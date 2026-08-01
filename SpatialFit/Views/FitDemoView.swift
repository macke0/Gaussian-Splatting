//
//  FitDemoView.swift
//  SpatialFit
//
//  Demovyn: nisch i RealityKit + zonlogik + krockmodal.
//
//  Två lägen. Utan skanning körs scenen med VIRTUELL kamera, så att demot
//  fungerar i simulatorn och på enheter utan LiDAR. Efter en RoomPlan-skanning
//  byts den mot passthrough, och nischen ankras där väggen faktiskt står.
//

import SwiftUI
import RealityKit

struct FitDemoView: View {

    @State private var model = FitDemoModel()
    @State private var controller = FitSceneController()

    // Kamerastyrning för den virtuella förhandsvisningen.
    @State private var yaw: Float = 0.35
    @State private var pitch: Float = 0.30
    @State private var distance: Float = 3.1
    @State private var dragStart: SIMD2<Float>?
    @State private var distanceStart: Float?

    @State private var showsScanner = false

    var body: some View {
        ZStack {
            sceneView
                .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    FitBadgeView(fit: model.fit)
                    scanButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                Spacer(minLength: 0)

                ProductPickerBar(verdicts: model.catalogVerdicts,
                                 selectedID: model.selectedProduct.id,
                                 onSelect: model.select)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            .animation(.snappy(duration: 0.25), value: model.selectedProduct.id)

            if model.showsCollisionAlert {
                CollisionAlertView(
                    fit: model.fit,
                    onDismiss: model.dismissAlert,
                    onSuggestAlternative: selectBestFittingProduct
                )
                .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.showsCollisionAlert)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showsScanner) {
            RoomScanView { scanned in
                model.apply(source: scanned)
            }
        }
    }

    private var scanButton: some View {
        Button {
            showsScanner = true
        } label: {
            Image(systemName: "cube.transparent")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .accessibilityLabel("Skanna rummet")
    }

    // MARK: - 3D

    @ViewBuilder
    private var sceneView: some View {
        if model.usesWorldTracking {
            augmentedSceneView
        } else {
            virtualSceneView
        }
    }

    /// Passthrough. Nischen hängs under ett världsankare med väggens vridning,
    /// så att den skannade geometrin hamnar där den faktiskt står.
    private var augmentedSceneView: some View {
        RealityView { content in
            content.camera = .spatialTracking

            controller.buildRoom(niche: model.niche, obstacles: model.obstacles)
            controller.render(model.fit)

            let anchor = AnchorEntity(.world(transform: model.worldFromNiche))
            anchor.addChild(controller.root)
            content.add(anchor)

        } update: { _ in
            controller.buildRoom(niche: model.niche, obstacles: model.obstacles)
            controller.render(model.fit)
        }
    }

    /// Virtuell kamera: fungerar i simulatorn och utan LiDAR.
    private var virtualSceneView: some View {
        RealityView { content in
            content.camera = .virtual

            controller.buildRoom(niche: model.niche, obstacles: model.obstacles)
            controller.render(model.fit)
            applyCamera()

            content.add(controller.root)
            content.add(controller.cameraRig)

        } update: { _ in
            // Körs när @Observable-tillståndet ovan ändras.
            controller.buildRoom(niche: model.niche, obstacles: model.obstacles)
            controller.render(model.fit)
            applyCamera()
        }
        .background(sceneBackground)
        .gesture(orbitGesture)
        .simultaneousGesture(zoomGesture)
    }

    private var sceneBackground: some View {
        LinearGradient(colors: [Color(red: 0.11, green: 0.12, blue: 0.15),
                                Color(red: 0.04, green: 0.04, blue: 0.06)],
                       startPoint: .top, endPoint: .bottom)
    }

    private var orbitGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? SIMD2(yaw, pitch)
                if dragStart == nil { dragStart = start }
                yaw = start.x - Float(value.translation.width) * 0.006
                pitch = start.y + Float(value.translation.height) * 0.004
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = distanceStart ?? distance
                if distanceStart == nil { distanceStart = base }
                distance = max(1.2, min(6.0, base / Float(value.magnification)))
            }
            .onEnded { _ in distanceStart = nil }
    }

    private func applyCamera() {
        controller.setCamera(yaw: yaw,
                             pitch: pitch,
                             distance: distance,
                             target: SIMD3(model.niche.center.x, 0.55, model.niche.center.z))
    }

    // MARK: - Åtgärder

    /// "Visa produkter som passar" – i skarpt läge en filtrerad PIM-sökning.
    /// Här: hoppa till den bredaste produkten som fortfarande får grönt.
    private func selectBestFittingProduct() {
        let candidate = model.catalogVerdicts
            .filter { $0.zone == .green }
            .max { $0.product.dimensions.width < $1.product.dimensions.width }?
            .product

        if let candidate {
            model.select(candidate)
        } else {
            model.dismissAlert()
        }
    }
}

#Preview {
    FitDemoView()
}
