//
//  IdentifyService.swift
//  SpatialFit
//
//  Frågar servern vad en pjäs i rummet är för sorts pjäs.
//
//  Telefonen väljer bilden och klipper ut lådan; servern ser bara utsnittet.
//  Rummet, måtten och geometrin lämnar aldrig enheten — servern målar och
//  tittar, den tolkar inte rummet.
//
//  Svaret är en GISSNING. Det får bli en etikett och ett sökord mot PIM, aldrig
//  ett mått.
//

import Foundation
import UIKit

struct IdentifyService: Sendable {

    let server: URL

    /// Vad modellen tror att den ser.
    struct Description: Sendable, Equatable, Decodable {
        /// Vad det är, ett eller två ord.
        let kind: String
        /// Det som skiljer just detta exemplar: material, kulör, typ.
        let detail: String
        /// 0–1. Under `Description.uncertain` är svaret inte värt att visa som
        /// ett påstående.
        let confidence: Double

        static let uncertain = 0.5
    }

    enum Failure: LocalizedError {
        case noPhotoShowsIt
        case couldNotCrop
        case server(String)
        case rejected(Int)

        var errorDescription: String? {
            switch self {
            case .noPhotoShowsIt:
                "Inget foto visar hela pjäsen."
            case .couldNotCrop:
                "Fotot gick inte att klippa ut ur."
            case .server(let detail):
                "Servern kunde inte identifiera pjäsen: \(detail)"
            case .rejected(let code):
                "Servern svarade \(code)."
            }
        }
    }

    /// Identifierar ett element ur de foton som togs på rummet.
    func describe(_ element: RoomElement,
                  keyframes: [Keyframe],
                  directory: URL) async throws -> Description {
        guard let crop = ObjectCrop.best(for: element, in: keyframes),
              let keyframe = keyframes.first(where: { $0.id == crop.keyframeID }) else {
            throw Failure.noPhotoShowsIt
        }

        let source = directory.appending(path: keyframe.imageFilename)
        guard let jpeg = Self.cut(crop, from: source) else { throw Failure.couldNotCrop }

        return try await send(jpeg, hint: element.detail ?? "")
    }

    // MARK: - Bilden

    /// Klipper ut rutan och kodar om till JPEG. Utsnittet är en bråkdel av
    /// fotot, så det är några tiotal kilobyte som går över nätet.
    private static func cut(_ crop: ObjectCrop.Crop, from source: URL) -> Data? {
        guard let image = UIImage(contentsOfFile: source.path)?.cgImage else { return nil }

        // Bilden på disk kan vara nedskalad i förhållande till det `Keyframe`
        // räknade med. Rutan är därför uttryckt i andelar innan den blir pixlar.
        let scale = CGPoint(x: CGFloat(image.width) / CGFloat(crop.imageSize.x),
                            y: CGFloat(image.height) / CGFloat(crop.imageSize.y))
        let rect = CGRect(x: CGFloat(crop.origin.x) * scale.x,
                          y: CGFloat(crop.origin.y) * scale.y,
                          width: CGFloat(crop.size.x) * scale.x,
                          height: CGFloat(crop.size.y) * scale.y)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard !rect.isEmpty, let cropped = image.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.9)
    }

    // MARK: - Anropet

    private func send(_ jpeg: Data, hint: String) async throws -> Description {
        let boundary = "spatialfit.\(UUID().uuidString)"
        var request = URLRequest(url: server.appending(path: "identify"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"hint\"\r\n\r\n".utf8))
        body.append(Data("\(hint)\r\n".utf8))
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"crop\"; filename=\"crop.jpg\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let detail = try? JSONDecoder().decode(ServerError.self, from: data) {
                throw Failure.server(detail.detail)
            }
            throw Failure.rejected(http.statusCode)
        }

        guard let described = try? JSONDecoder().decode(Description.self, from: data) else {
            throw Failure.server("oväntat svar på identifieringen")
        }
        return described
    }

    private struct ServerError: Decodable {
        let detail: String
    }
}
