//
//  ProductPlacementView.swift
//  SpatialFit
//
//  Vägen från ett sparat rum till kollisionsmotorn: välj vilken nisch produkten
//  ska stå i, prova sedan produkter mot den. Nischvalet är en UI-fråga –
//  `NicheFinder` rangordnar men gissar inte åt kunden.
//

import SwiftUI

struct ProductPlacementView: View {

    let room: SavedRoom
    let store: RoomStore

    @Environment(\.dismiss) private var dismiss
    @State private var niches: [ScannedNiche] = []
    @State private var selected: ScannedNiche?

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    FitDemoView(source: selected)
                } else {
                    nicheList
                }
            }
            .navigationTitle(selected == nil ? "Välj plats" : "Prova produkter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Stäng") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if selected != nil {
                        Button("Byt plats") { selected = nil }
                    }
                }
            }
        }
        .task { niches = store.niches(in: room) }
    }

    private var nicheList: some View {
        List(niches) { found in
            Button {
                selected = found
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(found.niche.dimensions.shortDescription)
                        .font(.headline)
                    Text("\(found.niche.label) · ±\(Units.format(found.niche.toleranceMM))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .overlay {
            if niches.isEmpty {
                ContentUnavailableView {
                    Label("Ingen nisch i rummet", systemImage: "questionmark.square.dashed")
                } description: {
                    Text("Skanningen behöver se två skåp eller vitvaror mot samma vägg med ett mellanrum emellan.")
                }
            }
        }
    }
}
