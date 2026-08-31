//
//  SPZStream.swift
//  SpatialFit
//
//  Läser telefonens `splat.spz` utan att spränga minnet.
//
//  Två fel i biblioteken gjorde att det nybakade rummet dödades av iOS — inte
//  kraschade, DÖDADES, signal 9 utan kraschrapport. Båda är minnesfel som växer
//  med filstorleken, och SH-banden gjorde filen 1,85 gånger större.
//
//  **1. Gissningen på uppackad storlek.** `spz-swift` vet inte hur stor den
//  uppackade filen blir, så den gissar (`GzipCompression.swift:92`):
//
//      let estimatedSize = max(compressed.count * 20, 65536)
//
//  Tjugo gånger en fil på 60,7 MB är **1,21 GB**, som allokeras och nollställs
//  på en gång. Räcker den inte fördubblas gissningen till tolv gigabyte. Men
//  gzip BEHÖVER inte gissas: formatets fyra sista byte är den okomprimerade
//  storleken. Vi läser den och allokerar exakt så mycket — 125 MB i stället för
//  1 210.
//
//  **2. Strömmen som inte var lat.** MetalSplatters `SPZSceneReader` bygger sin
//  `AsyncThrowingStream` med en SYNKRON stängning och obegränsad buffert, så
//  hela filen packas upp till `SplatPoint` innan konsumenten fått en enda klump.
//  Vid grad 0 bär varje punkt en heap-array på 48 byte, vid grad 3 på 288 —
//  2 miljoner gaussare blir 675 MB i stället för 215. Vi lämnar i stället
//  klumpar genom en stängning, och då finns ingen buffert som kan svälla.
//
//  Det här ersätter inte `AutodetectSceneReader` — PLY och `.splat` går kvar
//  dit — utan bara vägen som faktiskt används av telefonens egna rum.
//

import Compression
import Foundation
import SplatIO
import simd
import spz

enum SPZStream {

    enum Failure: LocalizedError {
        case notSPZ
        case decompressionFailed
        case truncated

        var errorDescription: String? {
            switch self {
            case .notSPZ: "Filen är inte en SPZ-fil."
            case .decompressionFailed: "Splatten gick inte att packa upp."
            case .truncated: "Splatten är avhuggen."
            }
        }
    }

    /// Går igenom filen och lämnar `batch` punkter i taget till `handle`.
    ///
    /// Returnerar antalet punkter och filens SH-grad. Att den lämnar ifrån sig
    /// klumparna genom en stängning i stället för en `AsyncSequence` är hela
    /// poängen: då finns det ingen buffert som kan svälla.
    static func read(_ url: URL,
                     batch: Int,
                     handle: ([SplatPoint]) async throws -> Void) async throws -> (count: Int, degree: Int) {
        let packed = try unpackFile(url)
        let count = Int(packed.numPoints)
        let degree = Int(packed.shDegree)
        // SPZ ligger i RUB inuti; PLY-konventionen är RDF, och det är den
        // resten av appen och MetalSplatters shaders räknar med.
        let converter = coordinateConverter(from: .rub, to: .rdf)
        let bands = extraCoefficients(degree)

        var points: [SplatPoint] = []
        points.reserveCapacity(batch)
        for index in 0..<count {
            let gaussian = packed.unpack(Int32(index), converter: converter)

            var harmonics = [SIMD3<Float>]()
            harmonics.reserveCapacity(bands + 1)
            harmonics.append(gaussian.color)
            for band in 0..<bands {
                harmonics.append(SIMD3(gaussian.shR[band],
                                       gaussian.shG[band],
                                       gaussian.shB[band]))
            }

            points.append(SplatPoint(
                position: gaussian.position,
                color: .sphericalHarmonicFloat(harmonics),
                opacity: .logitFloat(gaussian.alpha),
                scale: .exponent(gaussian.scale),
                rotation: simd_quatf(ix: gaussian.rotation.x,
                                     iy: gaussian.rotation.y,
                                     iz: gaussian.rotation.z,
                                     r: gaussian.rotation.w)))

            guard points.count >= batch else { continue }
            try await handle(points)
            points.removeAll(keepingCapacity: true)
        }
        if !points.isEmpty { try await handle(points) }
        return (count, degree)
    }

    // MARK: - Filen

    /// Packar upp gzip:en och delar upp den i `PackedGaussians` fält.
    ///
    /// Rå deflate blir kvar när gzip-höljet skalats av. Apples `Compression`
    /// kallar det `COMPRESSION_ZLIB`, vilket är missvisande — den vill INTE ha
    /// zlib-huvudet, bara nyttolasten.
    private static func unpackFile(_ url: URL) throws -> PackedGaussians {
        // Kartlagd, inte inläst: 60 MB behöver aldrig ligga i appens eget minne.
        let file = try Data(contentsOf: url, options: .mappedIfSafe)
        let body = try deflatePayload(file)
        let data = try inflate(body, into: originalSize(file))
        return try fields(of: data)
    }

    /// Gzip-höljets sista fyra byte: den okomprimerade storleken mod 2^32.
    ///
    /// Rummen är hundratals megabyte, aldrig fyra gigabyte, så överspillet i
    /// formatet spelar ingen roll här.
    private static func originalSize(_ file: Data) throws -> Int {
        guard file.count > 18 else { throw Failure.truncated }
        let tail = file.index(file.endIndex, offsetBy: -4)
        return Int(file[tail...].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    }

    /// Skalar av gzip-huvudet och de åtta byten på slutet.
    private static func deflatePayload(_ file: Data) throws -> Data {
        let start = file.startIndex
        guard file.count >= 18, file[start] == 0x1f, file[start + 1] == 0x8b else {
            throw Failure.notSPZ
        }
        let flags = file[start + 3]
        var offset = 10
        if flags & 0x04 != 0 {                                  // FEXTRA
            let length = Int(file[start + offset]) | (Int(file[start + offset + 1]) << 8)
            offset += 2 + length
        }
        for mask in [UInt8(0x08), UInt8(0x10)] where flags & mask != 0 {  // FNAME, FCOMMENT
            while offset < file.count && file[start + offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }                    // FHCRC
        guard offset < file.count - 8 else { throw Failure.truncated }
        return file[(start + offset)..<(file.endIndex - 8)]
    }

    private static func inflate(_ payload: Data, into size: Int) throws -> Data {
        guard size > 0 else { throw Failure.decompressionFailed }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            payload.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, payload.count,
                    nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.decompressionFailed }
        return output
    }

    /// Delar den uppackade filen i `PackedGaussians` sex byteknippen.
    ///
    /// Samma huvud som `spz-swift` läser, men vi behöver göra det själva: dess
    /// egen avkodare är `internal` och bara nåbar genom gissningen ovan.
    private static func fields(of data: Data) throws -> PackedGaussians {
        let header = 16
        guard data.count >= header else { throw Failure.truncated }

        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let version = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) })
        guard magic == 0x5053_474e, (1...3).contains(version) else { throw Failure.notSPZ }

        let degree = Int32(data[data.startIndex + 12])
        guard degree <= 3 else { throw Failure.notSPZ }

        var packed = PackedGaussians()
        packed.numPoints = Int32(count)
        packed.shDegree = degree
        packed.fractionalBits = Int32(data[data.startIndex + 13])
        packed.antialiased = data[data.startIndex + 14] & 0x1 != 0
        packed.usesQuaternionSmallestThree = version >= 3

        // Fälten ligger i den här ordningen i filen, och bredden per gaussare
        // beror på versionen: v1 lade positioner i float16, v3 packar
        // rotationen som "smallest three".
        var offset = data.startIndex + header
        func take(_ width: Int) throws -> [UInt8] {
            let end = offset + count * width
            guard end <= data.endIndex else { throw Failure.truncated }
            defer { offset = end }
            return Array(data[offset..<end])
        }

        packed.positions = try take(3 * (version == 1 ? 2 : 3))
        packed.alphas = try take(1)
        packed.colors = try take(3)
        packed.scales = try take(3)
        packed.rotations = try take(version >= 3 ? 4 : 3)
        packed.sh = try take(extraCoefficients(Int(degree)) * 3)
        return packed
    }

    // MARK: - Smått

    /// Antalet SH-koefficienter utöver nolltermen, per färgkanal.
    private static func extraCoefficients(_ degree: Int) -> Int {
        switch degree {
        case 1: 3
        case 2: 8
        case 3: 15
        default: 0
        }
    }
}
