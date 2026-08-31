//
//  RoomLibraryView.swift
//  SpatialFit
//
//  Startskärmen: rummen kunden redan skannat. Tryck på ett rum för att se det
//  i 3D, eller skanna ett nytt.
//

import SwiftUI

struct RoomLibraryView: View {

    @State private var store = RoomStore()
    @State private var queue = BakeQueue()
    @State private var showsScanner = false
    @State private var openRoom: SavedRoom?
    /// Referensfilerna, om några lagts i appens mapp. Se `BenchmarkSplatView`.
    @State private var benchmarks = BenchmarkSplatView.availableFiles()

    var body: some View {
        NavigationStack {
            Group {
                if store.rooms.isEmpty {
                    empty
                } else {
                    roomList
                }
            }
            .navigationTitle("Mina rum")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Skanna rum", systemImage: "plus") { showsScanner = true }
                }
                // Bara när en referensfil ligger i appens mapp. Knappen är ett
                // mätinstrument och ingen funktion — kunden ser den aldrig.
                if !benchmarks.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            BenchmarkSplatView(urls: benchmarks)
                        } label: {
                            Label("Referens", systemImage: "ruler")
                        }
                    }
                }
            }
            .navigationDestination(item: $openRoom) { room in
                RoomViewerView(room: room, store: store, queue: queue)
            }
        }
        // Bakningar som pågick när appen stängdes lever kvar på servern. Att
        // koppla upp sig mot dem igen är billigare än att ladda upp allt på nytt.
        .task { queue.resumePending(in: store) }
        .sheet(isPresented: $showsScanner) {
            RoomScanView(store: store) { saved in
                openRoom = saved
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Inga rum ännu", systemImage: "square.split.bottomrightquarter")
        } description: {
            Text("Skanna ditt rum med LiDAR så sparas det här. Sedan kan du gå runt i det i 3D och prova produkter.")
        } actions: {
            Button("Skanna rum") { showsScanner = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var roomList: some View {
        List {
            ForEach(store.rooms) { room in
                Button {
                    openRoom = room
                } label: {
                    row(room)
                }
                .swipeActions {
                    Button("Ta bort", role: .destructive) { store.delete(room) }
                }
            }
        }
    }

    private func row(_ room: SavedRoom) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .frame(width: 34)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(room.name)
                    .font(.headline)
                Text("\(room.scannedAtDescription) · \(nicheSummary(room))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Rummet går att öppna och mäta i medan det målas. Snurran är där
            // för att bakningen ska synas, inte för att den ska inväntas.
            if queue.isWorking(room) {
                Spacer(minLength: 0)
                ProgressView()
            }
        }
        .padding(.vertical, 4)
    }

    private func nicheSummary(_ room: SavedRoom) -> String {
        switch room.nicheCount {
        case 0: "ingen nisch"
        case 1: "1 nisch"
        default: "\(room.nicheCount) nischer"
        }
    }
}
