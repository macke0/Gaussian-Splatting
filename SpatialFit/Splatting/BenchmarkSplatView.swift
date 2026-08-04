//
//  BenchmarkSplatView.swift
//  SpatialFit
//
//  En känd god splat, renderad med vår renderare. Ett mätinstrument, inte en
//  funktion för kunden.
//
//  Frågan den svarar på är den enda som inte gick att avgöra inifrån vårt eget
//  material: när rummet ser suddigt ut, ligger felet i Metal-renderaren eller i
//  det vi matar den med? Visas en fil tränad av referensimplementationen skarpt
//  är renderaren frikänd, och all vidare felsökning hör hemma på servern.
//
//  Filerna läggs i appens mapp via Filer-appen, inte i appbundeln: en referens
//  på ett par hundra megabyte har inget i en kunds nedladdning att göra, och
//  den ska gå att byta ut utan att bygga om.
//
//  Utan en kamerapose ur datasetet säger vyn ingenting. Mätt på Inrias `train`:
//  ur en fritt vald bana ser scenen ut som färgat dis, och det gör den för att
//  splatten aldrig blivit visad därifrån — samma sak som `SplatRoomView.reach`
//  beskriver för vårt eget rum. Ligger `benchmark-kameror.json` bredvid filen
//  börjar vyn därför i den första kamerans pose, och först då är bilden ett
//  svar på frågan.
//

import simd
import SwiftUI

struct BenchmarkSplatView: View {

    let url: URL

    /// Punkten kameran kretsar kring: en bit rakt fram ur datasetets första
    /// kamera, så att vyn börjar exakt där en av träningsbilderna togs.
    private let center: SIMD3<Float>?
    @State private var yaw: Float
    @State private var pitch: Float
    /// Meter när posen är känd, annars scenradier. Se `SplatRoomView.range`.
    @State private var distance: Float
    @State private var dragStart: SIMD2<Float>?
    @State private var distanceStart: Float?
    @State private var status = "läser filen …"

    init(url: URL) {
        self.url = url

        let pose = Self.pose(beside: url)
        center = pose?.center
        _yaw = State(initialValue: pose?.yaw ?? 0.6)
        _pitch = State(initialValue: pose?.pitch ?? 0.45)
        _distance = State(initialValue: pose?.distance ?? 2)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.black, Color(white: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            SplatRoomView(url: url, standingAt: center, asAuthored: true,
                          yaw: $yaw, pitch: $pitch, distance: $distance) { result in
                switch result {
                case .success(let count):
                    status = "\(count) gaussare\(center == nil ? " · ingen pose" : "")"
                case .failure(let error):
                    status = "gick inte att läsa: \(error.localizedDescription)"
                }
            }
            .ignoresSafeArea()
            .gesture(orbit)
            .simultaneousGesture(zoom)

            Text(status)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.thinMaterial, in: Capsule())
                .padding(.bottom, 24)
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var orbit: some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStart ?? SIMD2(yaw, pitch)
                if dragStart == nil { dragStart = start }
                yaw = start.x - Float(value.translation.width) * 0.008
                pitch = start.y + Float(value.translation.height) * 0.006
            }
            .onEnded { _ in dragStart = nil }
    }

    private var zoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let base = distanceStart ?? distance
                if distanceStart == nil { distanceStart = base }
                // Vida gränser: poängen med vyn är att kunna gå ända in och
                // titta på en enskild yta, och en främmande scen kan vara vad
                // som helst stor.
                distance = min(max(base / Float(value.magnification), 0.05), 40)
            }
            .onEnded { _ in distanceStart = nil }
    }
}

extension BenchmarkSplatView {
    /// Referensfilen om någon lagts i appens mapp.
    ///
    /// Vilken splatfil som helst duger så länge den heter så här; ändelsen
    /// väljer läsare. Saknas den finns ingen knapp att trycka på.
    static func availableFile() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }

        return ["benchmark.ply", "benchmark.spz", "benchmark.splat"]
            .map(documents.appendingPathComponent)
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Vyns startläge, om datasetets kameror ligger bredvid splatfilen.
    struct Pose {
        var center: SIMD3<Float>
        var yaw: Float
        var pitch: Float
        var distance: Float
    }

    /// Datasetets `cameras.json` som Inria skriver den: `rotation` är kamerans
    /// vridning ut i världen, radvis, och kameran tittar längs sitt eget +z.
    private struct DatasetCamera: Decodable {
        let position: [Float]
        let rotation: [[Float]]
    }

    static func pose(beside url: URL) -> Pose? {
        let file = url.deletingLastPathComponent()
            .appendingPathComponent("benchmark-kameror.json")
        guard let data = try? Data(contentsOf: file),
              let cameras = try? JSONDecoder().decode([DatasetCamera].self, from: data),
              let camera = cameras.first,
              camera.position.count == 3, camera.rotation.count == 3,
              camera.rotation.allSatisfy({ $0.count == 3 }) else { return nil }

        let eye = SIMD3(camera.position[0], camera.position[1], camera.position[2])
        // Tredje kolumnen, alltså kamerans z-axel uttryckt i världen.
        let forward = normalize(SIMD3(camera.rotation[0][2],
                                      camera.rotation[1][2],
                                      camera.rotation[2][2]))

        // Målpunkten läggs rakt fram längs blickriktningen, så kameran hamnar
        // exakt på `eye` oavsett hur långt fram den läggs. Avståndet väljer
        // alltså bara var zoomen har sin vridpunkt.
        let distance: Float = 4
        let direction = -forward
        return Pose(center: eye + forward * distance,
                    yaw: atan2(direction.x, direction.z),
                    pitch: asin(direction.y),
                    distance: distance)
    }
}
