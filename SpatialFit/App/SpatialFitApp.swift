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

    var body: some Scene {
        WindowGroup {
            FitDemoView()
        }
    }
}
