//
//  SceneMeshRecorder.swift
//  SpatialFit
//
//  Hämtar ARKits rekonstruerade yta ur den session RoomPlan redan kör.
//
//  RoomPlan bygger sin tolkning ovanpå ARKits scenrekonstruktion, och ARKit
//  lägger den som `ARMeshAnchor` i sessionen. Anchors uppdateras och slås ihop
//  medan skanningen pågår, så det räcker att läsa dem en gång på slutet — då
//  ligger hela rummet där.
//
//  Buffertarna i en `ARMeshAnchor` ägs av ARKit och kan skrivas över när som
//  helst. De kopieras därför direkt, inte sparas som referens.
//

import Foundation
import ARKit
import simd

@MainActor
enum SceneMeshRecorder {

    /// Ytan hela sessionen sett, i världskoordinater.
    ///
    /// Tom om enheten kör utan scenrekonstruktion — då finns bara RoomPlans
    /// tolkning att visa.
    static func snapshot(of session: ARSession) -> SceneMesh {
        guard let anchors = session.currentFrame?.anchors else { return SceneMesh() }

        var mesh = SceneMesh()
        for anchor in anchors.compactMap({ $0 as? ARMeshAnchor }) {
            append(anchor, to: &mesh)
        }
        return mesh
    }

    private static func append(_ anchor: ARMeshAnchor, to mesh: inout SceneMesh) {
        let geometry = anchor.geometry
        let vertices = geometry.vertices
        let faces = geometry.faces

        guard vertices.format == .float3, faces.bytesPerIndex == 4,
              faces.primitiveType == .triangle else { return }

        let base = UInt32(mesh.positions.count)
        let transform = anchor.transform

        // `float3` i en `ARGeometrySource` är packad till 12 byte. Läses den
        // som `SIMD3<Float>`, som är utfylld till 16, glider varje hörn.
        let vertexBuffer = vertices.buffer.contents()
        mesh.positions.reserveCapacity(mesh.positions.count + vertices.count)
        for index in 0..<vertices.count {
            let pointer = vertexBuffer.advanced(by: vertices.offset + vertices.stride * index)
            let local = pointer.assumingMemoryBound(to: (Float, Float, Float).self).pointee
            let world = transform * SIMD4<Float>(local.0, local.1, local.2, 1)
            mesh.positions.append(SIMD3(world.x, world.y, world.z))
        }

        let indexCount = faces.count * faces.indexCountPerPrimitive
        let faceBuffer = faces.buffer.contents().assumingMemoryBound(to: UInt32.self)
        mesh.indices.reserveCapacity(mesh.indices.count + indexCount)
        for index in 0..<indexCount {
            mesh.indices.append(base + faceBuffer[index])
        }
    }
}
