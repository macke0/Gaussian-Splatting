//
//  SpatialFitApp.swift
//  SpatialFit
//

import SwiftUI
import RealityKit

@main
struct SpatialFitApp: App {

    init() {
        // ECS-registrering måste ske innan första scenen byggs.
        PulseComponent.registerComponent()
        PulseSystem.registerSystem()
    }

    // SwiftUI.Scene måste kvalificeras – RealityKit exporterar också en Scene.
    var body: some SwiftUI.Scene {
        WindowGroup {
            FitDemoView()
        }
    }
}
