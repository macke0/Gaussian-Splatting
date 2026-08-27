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
//  den ska gå att byta ut utan att bygga om. Ligger flera där går de att bläddra
//  mellan — två träningskörningar sida vid sida är hela poängen när frågan är
//  vilken av dem som blev skarpast.
//
//  `Som skriven` styr om filen renderas som en främmande fil eller som en av
//  våra egna, se `SplatRoomView.asAuthored`. Den sitter i verktygsfältet och
//  inte i koden för att vyn också används på filer VÅR tränare skrivit — och
//  den är AV som förval, för det är det vanliga fallet numera. Slås den på för
//  en av våra egna filer står rummet upp och ner och gammat blir fel.
//
//  Kameran går fritt här (`SplatRoomView.roaming`). Väggspärren som håller
//  kunden inne i rummet klipper `distance` mot en tredjedel av rumsradien, och
//  då dör zoomen: större delen av gestens område ger ingen rörelse alls. Att
//  granska en träningskörning kräver att man kan backa ut och gå ända in.
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

    /// Filerna i appens mapp. Vyn börjar på den första.
    let urls: [URL]

    /// Poserna läses en gång, vid bygget, och inte i `onAppear`. Renderaren får
    /// sin startpunkt när den SKAPAS; kommer den efteråt har kameran redan
    /// hamnat i mitten av lådan, alltså utanför rummet, och bilden blir mjölkig.
    private let poses: [URL: Pose]

    @State private var index = 0
    @State private var yaw: Float
    @State private var pitch: Float
    /// Meter när posen är känd, annars scenradier. Se `SplatRoomView.range`.
    @State private var distance: Float
    @State private var asAuthored = false
    @State private var dragStart: SIMD2<Float>?
    @State private var distanceStart: Float?
    @State private var status = "läser filen …"

    init(urls: [URL]) {
        self.urls = urls
        let read = Dictionary(uniqueKeysWithValues:
            urls.compactMap { url in Self.pose(beside: url).map { (url, $0) } })
        poses = read

        let first = urls.first.flatMap { read[$0] }
        _yaw = State(initialValue: first?.yaw ?? 0.6)
        _pitch = State(initialValue: first?.pitch ?? 0.45)
        _distance = State(initialValue: first?.distance ?? 2)
    }

    private var url: URL { urls[min(index, urls.count - 1)] }

    /// Punkten kameran kretsar kring: en bit rakt fram ur datasetets första
    /// kamera, så att vyn börjar exakt där en av träningsbilderna togs.
    private var center: SIMD3<Float>? { poses[url]?.center }

    var body: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(colors: [.black, Color(white: 0.18)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            SplatRoomView(url: url, standingAt: center, asAuthored: asAuthored,
                          roaming: true,
                          yaw: $yaw, pitch: $pitch, distance: $distance) { result in
                switch result {
                case .success(let splat):
                    status = "\(splat.count) gaussare · SH-grad \(splat.shDegree)"
                        + (center == nil ? " · ingen pose" : "")
                case .failure(let error):
                    status = "gick inte att läsa: \(error.localizedDescription)"
                }
            }
            // Både filen och färghanteringen sitter i renderaren när den byggs.
            .id("\(url.lastPathComponent)-\(asAuthored)")
            .ignoresSafeArea()
            .gesture(orbit)
            .simultaneousGesture(zoom)

            HStack(spacing: 12) {
                Button("Närmare", systemImage: "plus.magnifyingglass") { step(0.7) }
                Text(status)
                    .font(.caption.monospacedDigit())
                Button("Längre bort", systemImage: "minus.magnifyingglass") { step(1 / 0.7) }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Toggle("Som skriven", systemImage: "paintpalette", isOn: $asAuthored)
                    .toggleStyle(.button)
            }
            if urls.count > 1 {
                ToolbarItem(placement: .bottomBar) {
                    Picker("Fil", selection: $index) {
                        ForEach(urls.indices, id: \.self) { position in
                            Text(urls[position].deletingPathExtension().lastPathComponent)
                                .tag(position)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .onChange(of: index) { adoptPose() }
    }

    /// Startläget för filen som visas. Varje fil får sin egen kamera, så att en
    /// jämförelse mellan två körningar sker ur samma vy som fotona togs i.
    private func adoptPose() {
        status = "läser filen …"
        let pose = poses[url]
        yaw = pose?.yaw ?? 0.6
        pitch = pose?.pitch ?? 0.45
        distance = pose?.distance ?? 2
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
                step(to: base / Float(value.magnification))
            }
            .onEnded { _ in distanceStart = nil }
    }

    /// Knapparna finns för att nypgesten inte går att göra i simulatorn, och
    /// för att den är fumlig med en hand på en telefon.
    private func step(_ factor: Float) { step(to: distance * factor) }

    /// Vida gränser: poängen med vyn är att kunna gå ända in och titta på en
    /// enskild yta, och en främmande scen kan vara hur stor som helst.
    private func step(to value: Float) {
        distance = min(max(value, 0.05), 40)
    }
}

extension BenchmarkSplatView {
    /// Referensfilerna som lagts i appens mapp.
    ///
    /// Vilken splatfil som helst duger så länge namnet börjar på `benchmark`;
    /// ändelsen väljer läsare. Finns ingen alls finns ingen knapp att trycka på.
    static func availableFiles() -> [URL] {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false),
              let files = try? FileManager.default.contentsOfDirectory(
                at: documents, includingPropertiesForKeys: nil) else { return [] }

        return files
            .filter { $0.lastPathComponent.hasPrefix("benchmark")
                && ["ply", "spz", "splat"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
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

    /// Kamerorna hör till en enskild fil och heter som den: `x.spz` letar efter
    /// `x-kameror.json`. Annars skulle två körningar av olika scener dela pose,
    /// och den andra hamna utanför sitt eget rum.
    static func pose(beside url: URL) -> Pose? {
        let file = url.deletingPathExtension()
        let named = URL(fileURLWithPath: file.path + "-kameror.json")
        guard let data = try? Data(contentsOf: named),
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
