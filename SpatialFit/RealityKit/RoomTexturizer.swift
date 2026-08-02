//
//  RoomTexturizer.swift
//  SpatialFit
//
//  Målar rummets mesh med de foton som togs under skanningen.
//
//  Ingen texturatlas byggs. I stället grupperas trianglarna efter vilken
//  kamerabild som såg dem bäst, och varje grupp blir en egen del med den
//  bilden som textur. Det ger full fotoupplösning utan att packa om pixlar,
//  och kostar bara en ritning per keyframe.
//
//  Materialet är avsiktligt `UnlitMaterial`: ljuset ligger redan i fotot.
//  Skulle ytan dessutom belysas av scenens lampor blir rummet dubbelbelyst.
//

import Foundation
import RealityKit
import simd

enum RoomTexturizer {

    enum Failure: LocalizedError {
        case noGeometry
        case noKeyframes
        case nothingVisible

        var errorDescription: String? {
            switch self {
            case .noGeometry: "Rummets 3D-modell saknar geometri."
            case .noKeyframes: "Inga foton sparades under skanningen."
            case .nothingVisible: "Ingen av bilderna täckte rummets ytor."
            }
        }
    }

    /// Bygger en fotograferad kopia av `source`.
    ///
    /// - Parameter directory: mappen där keyframe-bilderna ligger.
    @MainActor
    static func texturize(source: Entity,
                          keyframes: [Keyframe],
                          directory: URL) async throws -> Entity {
        guard !keyframes.isEmpty else { throw Failure.noKeyframes }

        let triangles = worldTriangles(of: source)
        guard !triangles.isEmpty else { throw Failure.noGeometry }

        // Miljontals projektioner. Ren simd-räkning, så den flyttas av huvudtråden.
        let groups = await Task.detached(priority: .userInitiated) {
            let depth = DepthMaps(keyframes: keyframes, directory: directory)
            return assign(triangles: triangles, to: keyframes, depth: depth.lookup)
        }.value
        guard !groups.isEmpty else { throw Failure.nothingVisible }

        let root = Entity()
        root.name = "TexturedRoom"

        for (keyframeID, group) in groups.sorted(by: { $0.key < $1.key }) {
            guard let keyframe = keyframes.first(where: { $0.id == keyframeID }),
                  let part = try? await texturedPart(group: group,
                                                     keyframe: keyframe,
                                                     directory: directory) else { continue }
            root.addChild(part)
        }

        guard !root.children.isEmpty else { throw Failure.nothingVisible }
        return root
    }

    // MARK: - Geometri ut ur den laddade modellen

    /// Plockar ut varje triangel i världskoordinater. `MeshResource` kan
    /// innehålla instanser av samma modell på flera platser, så instansernas
    /// transform måste vävas ihop med entitetens.
    static func worldTriangles(of entity: Entity) -> [ViewSelection.Triangle] {
        var result: [ViewSelection.Triangle] = []
        collect(entity: entity, into: &result)
        return result
    }

    private static func collect(entity: Entity, into result: inout [ViewSelection.Triangle]) {
        if let model = entity.components[ModelComponent.self] {
            let worldFromEntity = entity.transformMatrix(relativeTo: nil)
            let contents = model.mesh.contents

            var handled = false
            for instance in contents.instances {
                guard let part = contents.models[instance.model] else { continue }
                append(model: part,
                       transform: worldFromEntity * instance.transform,
                       into: &result)
                handled = true
            }
            if !handled {
                for part in contents.models {
                    append(model: part, transform: worldFromEntity, into: &result)
                }
            }
        }

        for child in entity.children {
            collect(entity: child, into: &result)
        }
    }

    private static func append(model: MeshResource.Model,
                               transform: simd_float4x4,
                               into result: inout [ViewSelection.Triangle]) {
        for part in model.parts {
            let positions = part.positions.elements
            guard let indices = part.triangleIndices?.elements else { continue }

            let world = positions.map { position -> SIMD3<Float> in
                let point = transform * SIMD4<Float>(position, 1)
                return SIMD3(point.x, point.y, point.z)
            }

            var index = 0
            while index + 2 < indices.count {
                let a = Int(indices[index])
                let b = Int(indices[index + 1])
                let c = Int(indices[index + 2])
                index += 3
                guard a < world.count, b < world.count, c < world.count else { continue }
                result.append(ViewSelection.Triangle(world[a], world[b], world[c]))
            }
        }
    }

    // MARK: - Fördelning på bilder

    private static func assign(triangles: [ViewSelection.Triangle],
                               to keyframes: [Keyframe],
                               depth: ViewSelection.DepthLookup) -> [Int: [ViewSelection.Triangle]] {
        var groups: [Int: [ViewSelection.Triangle]] = [:]
        for triangle in triangles {
            guard let keyframe = ViewSelection.best(for: triangle,
                                                    among: keyframes,
                                                    depth: depth) else { continue }
            groups[keyframe.id, default: []].append(triangle)
        }
        return groups
    }

    // MARK: - Bygga en texturerad del

    private static func texturedPart(group: [ViewSelection.Triangle],
                                     keyframe: Keyframe,
                                     directory: URL) async throws -> Entity {
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var coordinates: [SIMD2<Float>] = []
        var indices: [UInt32] = []

        positions.reserveCapacity(group.count * 3)
        indices.reserveCapacity(group.count * 3)

        for triangle in group {
            let corners = [triangle.a, triangle.b, triangle.c]
            // Alla tre hörnen måste ha en texturkoordinat. Ett halvt hörn ger
            // en trasig triangel, inte en delvis målad.
            guard let normal = triangle.normal,
                  let projections = corners.mapAllOrNil({ keyframe.project($0) }) else { continue }

            for (corner, projection) in zip(corners, projections) {
                indices.append(UInt32(positions.count))
                positions.append(corner)
                normals.append(normal)
                coordinates.append(projection.textureCoordinate(imageSize: keyframe.imageSize))
            }
        }

        var descriptor = MeshDescriptor(name: "kf\(keyframe.id)")
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.textureCoordinates = MeshBuffers.TextureCoordinates(coordinates)
        descriptor.primitives = .triangles(indices)

        let mesh = try MeshResource.generate(from: [descriptor])
        let texture = try await TextureResource(contentsOf: directory.appending(path: keyframe.imageFilename))

        var material = UnlitMaterial()
        material.color = .init(tint: .white, texture: .init(texture))
        // Väggarna är enkelsidiga. Utan detta försvinner de när man står inne
        // i rummet och tittar på insidan.
        material.faceCulling = .none

        return ModelEntity(mesh: mesh, materials: [material])
    }
}

/// Djupkartorna inlästa i minnet. 256×192 floats per keyframe – små nog att
/// hålla allihop, vilket gör ocklusionstestet till en enkel uppslagning.
private struct DepthMaps {

    private let maps: [Int: [Float]]

    init(keyframes: [Keyframe], directory: URL) {
        var maps: [Int: [Float]] = [:]
        for keyframe in keyframes where keyframe.depthSize.x > 0 {
            guard let data = try? Data(contentsOf: directory.appending(path: keyframe.depthFilename)) else { continue }
            let count = Int(keyframe.depthSize.x) * Int(keyframe.depthSize.y)
            guard data.count >= count * MemoryLayout<Float>.size else { continue }
            maps[keyframe.id] = data.withUnsafeBytes { raw in
                Array(raw.bindMemory(to: Float.self).prefix(count))
            }
        }
        self.maps = maps
    }

    var lookup: ViewSelection.DepthLookup {
        let maps = self.maps
        return { keyframe, index in
            guard let map = maps[keyframe.id], index >= 0, index < map.count else { return nil }
            let value = map[index]
            return value.isFinite && value > 0 ? value : nil
        }
    }
}

private extension Array {
    /// Avbildar hela listan, eller ger `nil` så snart ett element saknas.
    func mapAllOrNil<T>(_ transform: (Element) -> T?) -> [T]? {
        var result: [T] = []
        result.reserveCapacity(count)
        for element in self {
            guard let mapped = transform(element) else { return nil }
            result.append(mapped)
        }
        return result
    }
}
