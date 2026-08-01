//
//  FitDemoModel.swift
//  SpatialFit
//
//  Tunn tillståndshållare. All beräkning ligger i CollisionEngine – den här
//  klassen väljer bara datakälla, håller vald produkt och exponerar resultatet.
//

import Foundation
import Observation
import simd

@Observable
final class FitDemoModel {

    private(set) var niche: Niche
    private(set) var obstacles: [Obstacle]
    private(set) var fit: FitResult
    /// Var nischen sitter i världen. Identitet för demodata, väggens vridning
    /// för en skannad nisch.
    private(set) var worldFromNiche: simd_float4x4

    /// Passthrough bara när nischen kommer ur en skanning – demodata har ingen
    /// plats i rummet att ankras mot.
    var usesWorldTracking: Bool { niche.source != .mock }

    let catalog: [Product]
    var policy: FitPolicy { didSet { recalculate() } }

    private(set) var selectedProduct: Product
    /// Användaren kan slå bort krockmodalen och ändå fortsätta titta på scenen.
    private var dismissedAlertForProductID: String?

    var showsCollisionAlert: Bool {
        fit.hasCollision && dismissedAlertForProductID != selectedProduct.id
    }

    init(source: any NicheSource = MockKitchenNiche(),
         catalog: [Product] = ProductCatalog.demo,
         policy: FitPolicy = .standard) {
        self.niche = source.niche
        self.obstacles = source.obstacles
        self.worldFromNiche = source.worldFromNiche
        self.catalog = catalog
        self.policy = policy
        let first = catalog.first ?? ProductCatalog.productA
        self.selectedProduct = first
        self.fit = CollisionEngine.evaluate(product: first,
                                            niche: source.niche,
                                            obstacles: source.obstacles,
                                            policy: policy)
    }

    func select(_ product: Product) {
        guard product.id != selectedProduct.id else { return }
        selectedProduct = product
        dismissedAlertForProductID = nil
        recalculate()
    }

    func dismissAlert() {
        dismissedAlertForProductID = selectedProduct.id
    }

    /// Byt datakälla i drift. Hit kommer RoomPlan-resultatet.
    func apply(source: any NicheSource) {
        niche = source.niche
        obstacles = source.obstacles
        worldFromNiche = source.worldFromNiche
        dismissedAlertForProductID = nil
        recalculate()
    }

    private func recalculate() {
        fit = CollisionEngine.evaluate(product: selectedProduct,
                                       niche: niche,
                                       obstacles: obstacles,
                                       policy: policy)
    }

    /// Snabbtest av alla produkter i katalogen mot den skannade nischen –
    /// grunden för "visa bara produkter som passar" i butiksflödet.
    var catalogVerdicts: [(product: Product, zone: FitZone)] {
        catalog.map { product in
            (product, CollisionEngine.evaluate(product: product,
                                               niche: niche,
                                               obstacles: obstacles,
                                               policy: policy).zone)
        }
    }
}
