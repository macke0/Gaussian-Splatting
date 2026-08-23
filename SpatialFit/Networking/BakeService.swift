//
//  BakeService.swift
//  SpatialFit
//
//  Rundturen till bakningsservern: skanningen upp, det målade rummet ner.
//
//  Bakningen tar minuter. Därför svarar uppladdningen med ett jobb-id och den
//  här klienten frågar efter tillståndet med jämna mellanrum — en anslutning som
//  står öppen i tio minuter överlever varken mobilnät eller att skärmen släcks.
//
//  Av samma skäl är starten och hämtningen skilda anrop. Jobbet lever på servern,
//  inte i telefonen: kunden ska kunna lägga undan appen medan rummet målas, och
//  ett id på disk räcker för att hitta tillbaka till samma bakning.
//
//  Resultatet hämtas som två raka nedladdningar. iOS kan packa ihop en mapp utan
//  beroenden, men inte packa upp en.
//

import Foundation

/// En bakning som ligger och går på en server. Sparas hos rummet, så att appen
/// kan avslutas och ändå hitta tillbaka till jobbet i stället för att börja om.
struct PendingBake: Codable, Sendable, Equatable {
    let job: String
    let server: URL
    let startedAt: Date
}

struct BakeService: Sendable {

    let server: URL

    /// Var servern hämtar färgen ifrån. Namnen är serverns egna.
    enum ColorSource: String, Sendable, CaseIterable, Identifiable {
        /// Väger ihop fotona direkt. Går på vilken maskin som helst.
        case blend
        /// Tränar en gaussian splat först och målar med renderade vyer. Bättre
        /// på hål och skarvar, men servern måste ha en CUDA-GPU.
        case splat

        var id: String { rawValue }

        var label: String {
            switch self {
            case .blend: "Blanda fotona"
            case .splat: "Gaussian splatting"
            }
        }
    }

    struct Summary: Sendable, Equatable {
        /// Andelen av ytan som minst ett foto såg. Resten är utfylld grå.
        let seenFraction: Double
        let triangleCount: Int
        /// Om servern också tränade fram en splat att titta på.
        let hasSplat: Bool
    }

    /// Splatten på disk, bredvid den bakade meshen. Ändelsen är inte kosmetisk:
    /// MetalSplatter väljer läsare efter den, och SPZ är tjugo byte per gaussare
    /// mot PLY:ns sextioåtta. Det är den skillnaden som gör att rummet får
    /// tillräckligt många gaussare per kvadratmeter för att bli skarpt.
    static let splatFilename = "splat.spz"

    enum Failure: LocalizedError {
        case noSurface
        case server(String)
        case rejected(Int)
        case timedOut

        var errorDescription: String? {
            switch self {
            case .noSurface:
                "Skanningen saknar den täta ytan. Skanna om rummet."
            case .server(let detail):
                "Servern kunde inte baka rummet: \(detail)"
            case .rejected(let code):
                "Servern svarade \(code)."
            case .timedOut:
                "Bakningen blev inte klar i tid."
            }
        }
    }

    /// Hur länge vi väntar innan vi ger upp. Att blanda fotona tar en dryg minut,
    /// men att träna en splat tar en kvart — tiden måste rymma den långsammare.
    private static let deadline: Duration = .seconds(3600)
    private static let pollInterval: Duration = .seconds(2)

    /// Hur stor en bit av en nedladdning är, och hur länge en bit får ta innan
    /// den räknas som förlorad. Fyra megabyte är litet nog att inte kosta mer än
    /// en halv minut att fråga om, och stort nog att en splat blir ett dussin
    /// frågor i stället för tusen.
    private static let chunkSize = 4 << 20
    private static let chunkTimeout: TimeInterval = 60
    private static let attemptsPerChunk = 6

    /// Packar `files` och laddar upp dem. Svarar när servern tagit emot jobbet,
    /// inte när det är klart: bakningen fortsätter där oavsett vad telefonen gör.
    func start(uploading files: [URL],
               colorSource: ColorSource = .blend) async throws -> String {
        let archive = try Self.archive(files)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        return try await upload(archive, colorSource: colorSource)
    }

    /// Väntar ut ett jobb som redan är igång och skriver `baked.mesh`,
    /// `baked.png` och eventuell `splat.spz` i `destination`. `report` får
    /// tillståndet så vyn kan visa det.
    @discardableResult
    func collect(_ job: String,
                 into destination: URL,
                 report: @Sendable (String) -> Void = { _ in }) async throws -> Summary {
        report("Servern bakar rummet…")
        let summary = try await wait(for: job)

        report("Hämtar det målade rummet…")
        try await download("mesh", of: job,
                           to: destination.appending(path: TexturedMesh.meshFilename))
        try await download("texture", of: job,
                           to: destination.appending(path: TexturedMesh.textureFilename))

        // Splatten är hundratals megabyte och kommer sist. Meshen är det som
        // rummet mäts och visas med om nedladdningen bryts på vägen.
        if summary.hasSplat {
            report("Hämtar splatten…")
            try await download("splat", of: job,
                               to: destination.appending(path: Self.splatFilename))
        }
        return summary
    }

    // MARK: - Stegen

    private func upload(_ archive: URL, colorSource: ColorSource) async throws -> String {
        let boundary = "spatialfit.\(UUID().uuidString)"
        var request = URLRequest(url: server.appending(path: "bake"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let body = try Self.multipart(archive, colorSource: colorSource, boundary: boundary)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: body)
        try Self.check(response, data)
        try? FileManager.default.removeItem(at: body)

        guard let started = try? JSONDecoder().decode(StartedJob.self, from: data) else {
            throw Failure.server("oväntat svar på uppladdningen")
        }
        return started.id
    }

    private func wait(for job: String) async throws -> Summary {
        let started = ContinuousClock.now
        while ContinuousClock.now - started < Self.deadline {
            try await Task.sleep(for: Self.pollInterval)

            let url = server.appending(path: "bake").appending(path: job)
            let data: Data, response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(from: url)
            } catch let error as URLError where Self.isTransient(error) {
                // Servern räknar med hela maskinen medan den bakar och hinner
                // inte alltid svara inom minuten URLSession väntar. Uppmätt på
                // en riktig bakning: en statusfråga var sextonde sekund under
                // de tio minuter atlasen målas. Jobbet lever kvar på servern
                // oavsett vad telefonen gör, så det vore slöseri att kasta en
                // bakning som är tio minuter in för att ett anrop inte kom
                // fram. Fråga igen tills fristen är slut.
                continue
            }
            try Self.check(response, data)

            guard let status = try? JSONDecoder().decode(JobStatus.self, from: data) else {
                throw Failure.server("oväntat svar på statusfrågan")
            }
            switch status.status {
            case "done":
                return Summary(seenFraction: status.seenFraction,
                               triangleCount: status.triangleCount,
                               hasSplat: status.hasSplat)
            case "failed":
                throw Failure.server(status.detail)
            default:
                continue
            }
        }
        throw Failure.timedOut
    }

    /// Hämtar en fil i bitar och lägger den i `destination`.
    ///
    /// Hela filen i ett svep höll inte. Splatten är 47 MB mot texturens 16, och
    /// på ett nät som tappar stora paket står strömmen still en stund här och
    /// där — URLSession räknar en minut utan byte som ett fel och kastar då allt
    /// som redan kommit fram. Uppmätt: texturen kom, splatten kom aldrig.
    ///
    /// Varje bit frågas därför för sig med `Range`, och en bit som inte kom fram
    /// frågas om från samma byte. Det som ligger på disk får ligga kvar.
    func download(_ name: String, of job: String, to destination: URL) async throws {
        let url = server.appending(path: "bake").appending(path: job).appending(path: name)
        let manager = FileManager.default

        // Skrivs vid sidan av och byter namn först när filen är hel: en avbruten
        // nedladdning ska inte se ut som ett bakat rum nästa gång appen startar.
        let partial = destination.appendingPathExtension("part")
        try? manager.removeItem(at: partial)
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw Failure.server("kunde inte skriva \(name)")
        }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        var offset = 0
        var total = Int.max
        while offset < total {
            var attempts = 0
            while true {
                do {
                    let (chunk, length) = try await Self.fetch(url, from: offset)
                    try handle.write(contentsOf: chunk)
                    offset += chunk.count
                    total = length
                    break
                } catch let error as URLError where Self.isTransient(error) {
                    attempts += 1
                    guard attempts < Self.attemptsPerChunk else { throw error }
                    try await Task.sleep(for: Self.pollInterval)
                }
            }
        }
        try handle.close()

        // Filen ersätter en tidigare bakning; `moveItem` vägrar skriva över.
        try? manager.removeItem(at: destination)
        try manager.moveItem(at: partial, to: destination)
    }

    /// Frågar efter en bit från och med `offset`. Svarar med bitens byte och
    /// hela filens längd, som servern skickar i `Content-Range`.
    private static func fetch(_ url: URL, from offset: Int) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = chunkTimeout
        request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)",
                         forHTTPHeaderField: "Range")

        let (data, response) = try await URLSession.shared.data(for: request)
        try check(response, data)

        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = Int(range.split(separator: "/").last ?? ""),
              !data.isEmpty else {
            throw Failure.server("servern skickar inte \(url.lastPathComponent) i bitar")
        }
        return (data, total)
    }

    // MARK: - Packning

    /// Hårdlänkar filerna till en egen mapp och zippar den. Rummets mapp
    /// innehåller också USDZ:n och `CapturedRoom`, som servern inte har någon
    /// användning för — de skulle bara göra uppladdningen större.
    private static func archive(_ files: [URL]) throws -> URL {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory.appending(path: "bake-\(UUID().uuidString)")
        let scan = staging.appending(path: "scan")
        try manager.createDirectory(at: scan, withIntermediateDirectories: true)

        var linked = 0
        for file in files where manager.fileExists(atPath: file.path) {
            try manager.linkItem(at: file, to: scan.appending(path: file.lastPathComponent))
            linked += 1
        }
        guard linked > 0 else { throw Failure.noSurface }

        var coordinationError: NSError?
        var result: Result<URL, Error> = .failure(Failure.server("kunde inte packa skanningen"))
        NSFileCoordinator().coordinate(readingItemAt: scan,
                                       options: .forUploading,
                                       error: &coordinationError) { zipped in
            // Arkivet finns bara så länge blocket kör.
            let destination = staging.appending(path: "scan.zip")
            result = Result { try manager.moveItem(at: zipped, to: destination) }
                .map { destination }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    /// Kroppen skrivs till fil i stället för att byggas i minnet. Ett rum med
    /// hundra foton och djupkartor är hundratals megabyte.
    private static func multipart(_ archive: URL,
                                  colorSource: ColorSource,
                                  boundary: String) throws -> URL {
        let body = archive.deletingLastPathComponent().appending(path: "body")
        let manager = FileManager.default
        manager.createFile(atPath: body.path, contents: nil)

        let handle = try FileHandle(forWritingTo: body)
        defer { try? handle.close() }

        // Färgkällan först: den är några byte, och servern läser fälten i tur
        // och ordning.
        let header = """
            --\(boundary)\r
            Content-Disposition: form-data; name="color_source"\r
            \r
            \(colorSource.rawValue)\r
            --\(boundary)\r
            Content-Disposition: form-data; name="scan"; filename="scan.zip"\r
            Content-Type: application/zip\r
            \r

            """
        try handle.write(contentsOf: Data(header.utf8))

        let source = try FileHandle(forReadingFrom: archive)
        defer { try? source.close() }
        while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
            try handle.write(contentsOf: chunk)
        }

        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }

    /// Om felet är sådant att samma fråga kan lyckas om en stund. Ett hus utan
    /// täckning och en server som inte hinner svara ser likadana ut härifrån,
    /// och båda går över.
    private static func isTransient(_ error: URLError) -> Bool {
        switch error.code {
        case .timedOut, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
            true
        default:
            false
        }
    }

    private static func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let data, let detail = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw Failure.server(detail.detail)
            }
            throw Failure.rejected(http.statusCode)
        }
    }

    // MARK: - Svaren

    private struct StartedJob: Decodable {
        let id: String
    }

    private struct JobStatus: Decodable {
        let status: String
        let detail: String
        let seenFraction: Double
        let triangleCount: Int
        let hasSplat: Bool
    }

    private struct ServerError: Decodable {
        let detail: String
    }
}
