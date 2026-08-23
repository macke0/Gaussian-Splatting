//
//  BakeServiceTests.swift
//  SpatialFitTests
//
//  Nedladdningen är det enda i klienten som måste överleva ett dåligt nät.
//  Splatten är 47 MB och kom aldrig fram när den hämtades i ett svep, medan
//  texturens 16 MB gjorde det — felet syns först när strömmen står still en
//  stund mitt i. Servern spelas därför av en `URLProtocol` som både kan svara
//  på `Range` och tappa en bit på vägen.
//

import Testing
import Foundation
@testable import SpatialFit

/// En server på fyra rader: svarar med den del av `payload` som frågan gäller,
/// och låter `failures` bestämma hur många frågor som faller bort först.
private final class RangeServer: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var payload = Data()
    /// Antal frågor som ska misslyckas innan servern börjar svara. Räknas ned.
    nonisolated(unsafe) static var failures = 0
    /// Om servern struntar i `Range` och skickar hela filen med 200.
    nonisolated(unsafe) static var ignoresRange = false
    nonisolated(unsafe) static var requestedRanges: [String] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let header = request.value(forHTTPHeaderField: "Range")
        Self.requestedRanges.append(header ?? "")

        if Self.failures > 0 {
            Self.failures -= 1
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }

        let total = Self.payload.count
        var status = 200
        var fields: [String: String] = [:]
        var body = Self.payload

        if let header, !Self.ignoresRange,
           let bounds = Self.bounds(header, total: total) {
            body = Self.payload.subdata(in: bounds)
            status = 206
            fields["Content-Range"] =
                "bytes \(bounds.lowerBound)-\(bounds.upperBound - 1)/\(total)"
        }
        fields["Content-Length"] = String(body.count)

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// `bytes=0-4194303` → `0..<4194304`, klippt mot filens slut.
    private static func bounds(_ header: String, total: Int) -> Range<Int>? {
        let digits = header.dropFirst("bytes=".count).split(separator: "-")
        guard digits.count == 2, let lower = Int(digits[0]), let upper = Int(digits[1]),
              lower < total else { return nil }
        return lower..<min(upper + 1, total)
    }
}

@Suite("Bakningsklienten", .serialized)
struct BakeServiceTests {

    private static let server = URL(string: "http://baker.test")!

    /// Något större än en bit, så att flera frågor krävs och sista biten blir
    /// ojämn — det är i skarven fel brukar sitta.
    private static func payload(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
    }

    private func fetch(_ payload: Data, droppingFirst failures: Int = 0,
                       ignoringRange: Bool = false) async throws -> Data {
        RangeServer.payload = payload
        RangeServer.failures = failures
        RangeServer.ignoresRange = ignoringRange
        RangeServer.requestedRanges = []
        URLProtocol.registerClass(RangeServer.self)
        defer { URLProtocol.unregisterClass(RangeServer.self) }

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "splat-\(UUID().uuidString).spz")
        defer { try? FileManager.default.removeItem(at: destination) }

        try await BakeService(server: Self.server)
            .download("splat", of: "jobb", to: destination)
        return try Data(contentsOf: destination)
    }

    @Test("En fil som spänner flera bitar kommer fram byte för byte")
    func multipleChunks() async throws {
        let payload = Self.payload(9 << 20 + 1234)
        #expect(try await fetch(payload) == payload)
        #expect(RangeServer.requestedRanges.first == "bytes=0-4194303")
        #expect(RangeServer.requestedRanges.count == 3)
    }

    @Test("En bit som faller bort frågas om från samma byte, inte från början")
    func retriesLostChunk() async throws {
        let payload = Self.payload(6 << 20)
        #expect(try await fetch(payload, droppingFirst: 2) == payload)
        // Två tappade frågor plus de två bitarna filen består av.
        #expect(RangeServer.requestedRanges.count == 4)
        #expect(RangeServer.requestedRanges.dropFirst(2).first == "bytes=0-4194303")
    }

    @Test("En fil mindre än en bit tar en enda fråga")
    func singleChunk() async throws {
        let payload = Self.payload(1000)
        #expect(try await fetch(payload) == payload)
        #expect(RangeServer.requestedRanges.count == 1)
    }

    @Test("Ett nät som aldrig bär igenom ger upp i stället för att fråga i evighet")
    func givesUp() async throws {
        await #expect(throws: URLError.self) {
            _ = try await fetch(Self.payload(5 << 20), droppingFirst: .max)
        }
    }

    @Test("En server som struntar i Range avvisas — halva filen är värre än ingen")
    func rejectsWholeFileResponse() async throws {
        await #expect(throws: BakeService.Failure.self) {
            _ = try await fetch(Self.payload(5 << 20), ignoringRange: true)
        }
    }

    @Test("Den halvfärdiga filen lämnas inte kvar som om rummet vore hämtat")
    func noLeftoverPartial() async throws {
        RangeServer.payload = Self.payload(5 << 20)
        RangeServer.failures = .max
        RangeServer.ignoresRange = false
        URLProtocol.registerClass(RangeServer.self)
        defer { URLProtocol.unregisterClass(RangeServer.self) }

        let destination = FileManager.default.temporaryDirectory
            .appending(path: "splat-\(UUID().uuidString).spz")
        _ = try? await BakeService(server: Self.server)
            .download("splat", of: "jobb", to: destination)

        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}
