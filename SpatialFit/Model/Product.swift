//
//  Product.swift
//  SpatialFit
//
//  Produktens sanning är PIM-boxen. Inget i appen får gissa mått ur en 3D-modell –
//  USDZ-filer är ofta approximativa, PIM-måtten är det kunden reklamerar mot.
//

import Foundation

struct Product: Identifiable, Equatable, Hashable, Sendable {
    let id: String
    /// Artikelnummer hos kedjan.
    let sku: String
    /// "Range Cooker 90 cm"
    let name: String
    /// Kort etikett för produktväljaren i botten.
    let shortLabel: String
    let brand: String
    /// PIM-bounding box i mm (b × h × d).
    let dimensions: Dimensions3D

    /// Extra fritt utrymme produkten kräver utöver sin egen box – t.ex.
    /// ventilationsspalt bakom en kyl eller svängradie för en lucka.
    /// Läggs till på respektive axel innan passformen prövas.
    var installationClearance: Dimensions3D = Dimensions3D(0, 0, 0)

    /// Namn på USDZ-assetet när riktiga modeller kopplas in (steg 3).
    var modelAssetName: String?

    /// Det mått motorn faktiskt jämför mot nischen.
    var requiredEnvelope: Dimensions3D {
        Dimensions3D(dimensions.width + installationClearance.width,
                     dimensions.height + installationClearance.height,
                     dimensions.depth + installationClearance.depth)
    }
}

enum ProductCatalog {
    /// Demokatalogen för MVP:n. Måtten är påhittade men ligger i rätt
    /// storleksordning för respektive produktkategori.
    static let demo: [Product] = [productA, productC, productB]

    /// GRÖN: 20 mm marginal i bredd mot en 600 mm-nisch.
    static let productA = Product(
        id: "A",
        sku: "BH-4711-580",
        name: "Induktionsspis 60 cm",
        shortLabel: "Spis 580",
        brand: "NordLine",
        dimensions: Dimensions3D(580, 850, 600)
    )

    /// RÖD: 900 mm produkt i 600 mm nisch → 150 mm överhäng per sida.
    static let productB = Product(
        id: "B",
        sku: "BH-9020-900",
        name: "Range Cooker 90 cm",
        shortLabel: "Range 900",
        brand: "NordLine Pro",
        dimensions: Dimensions3D(900, 880, 600)
    )

    /// GUL: 4 mm marginal – den klassiska returorsaken. Passar på pappret,
    /// men inte när väggen lutar 3 mm.
    static let productC = Product(
        id: "C",
        sku: "BH-4820-596",
        name: "Kombispis 60 cm",
        shortLabel: "Kombi 596",
        brand: "NordLine",
        dimensions: Dimensions3D(596, 890, 620)
    )
}
