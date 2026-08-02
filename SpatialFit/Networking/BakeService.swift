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
//  Resultatet hämtas som två raka nedladdningar. iOS kan packa ihop en mapp utan
//  beroenden, men inte packa upp en.
//

import Foundation

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
    }

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

    /// Hur länge vi väntar innan vi ger upp. Ett rum på en halv miljon trianglar
    /// tar några minuter; tar det längre är något fel med servern.
    private static let deadline: Duration = .seconds(900)
    private static let pollInterval: Duration = .seconds(2)

    /// Packar `files`, laddar upp dem och skriver `baked.mesh` och `baked.png`
    /// i `destination`. `report` får jobbets tillstånd så vyn kan visa det.
    @discardableResult
    func bake(uploading files: [URL],
              into destination: URL,
              colorSource: ColorSource = .blend,
              report: @Sendable (String) -> Void = { _ in }) async throws -> Summary {
        let archive = try Self.archive(files)
        defer { try? FileManager.default.removeItem(at: archive.deletingLastPathComponent()) }

        report("Laddar upp skanningen…")
        let job = try await start(archive, colorSource: colorSource)

        report("Servern bakar rummet…")
        let summary = try await wait(for: job)

        report("Hämtar det målade rummet…")
        try await download("mesh", of: job,
                           to: destination.appending(path: TexturedMesh.meshFilename))
        try await download("texture", of: job,
                           to: destination.appending(path: TexturedMesh.textureFilename))
        return summary
    }

    // MARK: - Stegen

    private func start(_ archive: URL, colorSource: ColorSource) async throws -> String {
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
            let (data, response) = try await URLSession.shared.data(from: url)
            try Self.check(response, data)

            guard let status = try? JSONDecoder().decode(JobStatus.self, from: data) else {
                throw Failure.server("oväntat svar på statusfrågan")
            }
            switch status.status {
            case "done":
                return Summary(seenFraction: status.seenFraction,
                               triangleCount: status.triangleCount)
            case "failed":
                throw Failure.server(status.detail)
            default:
                continue
            }
        }
        throw Failure.timedOut
    }

    private func download(_ name: String, of job: String, to destination: URL) async throws {
        let url = server.appending(path: "bake").appending(path: job).appending(path: name)
        let (temporary, response) = try await URLSession.shared.download(from: url)
        try Self.check(response, nil)

        // Filen ersätter en tidigare bakning; `moveItem` vägrar skriva över.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
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
    }

    private struct ServerError: Decodable {
        let detail: String
    }
}
