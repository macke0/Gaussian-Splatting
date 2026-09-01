//
//  BackdropRenderer.swift
//  SpatialFit
//
//  Ritar den uppmätta ytan under splatten och fogar ihop de två.
//
//  Varför det behövs: splatten är genomskinlig där ingen fotograferat, och de
//  hålen är precis de riktningar rummet ser trasigt ur — mätt ligger 6,8 % av
//  ytan utanför varje foto. Meshen är däremot mätt hela vägen runt, och ligger
//  sju millimeter från splattens yta. Under splatten fyller den hålen med något
//  solitt i stället för med genomsikt.
//
//  Varför inte bara låta MetalSplatter rita meshen först: renderaren rensar sin
//  färgbuffert (`loadAction = .clear`) och testar aldrig djup
//  (`depthCompareFunction = .always`). Allt som ritats före den försvinner. Därför
//  får splatten en egen ruta att rita i, och den läggs över efteråt.
//

import Foundation
import Metal
import MetalKit
import simd

@MainActor
final class BackdropRenderer {

    private struct Uniforms {
        var viewProjection: simd_float4x4
        var eye: SIMD3<Float>
        var tint: SIMD3<Float>
    }

    /// Ytans färg när rummet inte är bakat. Ljust varmgrått: mörkare än
    /// splattens väggar brukar vara, så att skarven syns som en mjukare yta och
    /// inte som ett fel.
    private static let plainTint = SIMD3<Float>(0.62, 0.60, 0.58)

    private let device: MTLDevice
    private let texturedPipeline: MTLRenderPipelineState
    private let plainPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState

    private var positions: MTLBuffer?
    private var normals: MTLBuffer?
    private var coordinates: MTLBuffer?
    private var indices: MTLBuffer?
    private var indexCount = 0
    private var atlas: MTLTexture?

    /// Rutan splatten ritas i innan den läggs över. Byggs om när vyn ändrar
    /// storlek.
    private var splatTexture: MTLTexture?

    var isReady: Bool { indexCount > 0 }

    /// `nil` när enheten inte kan bygga rörledningarna. Då ritas splatten som
    /// förr, utan bakgrund — sämre, men inte trasigt.
    init?(device: MTLDevice, colorFormat: MTLPixelFormat, depthFormat: MTLPixelFormat) {
        guard let library = try? device.makeDefaultLibrary(bundle: .main) else { return nil }
        self.device = device

        // Ingen av rörledningarna blandar i hårdvaran. Hopfogningen väger
        // samman splatten och ytan själv i `compositeFragment`, för bara där
        // går det att se hur mycket splatten faktiskt täcker.
        func pipeline(_ vertex: String, _ fragment: String,
                      depth: MTLPixelFormat) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depth
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let textured = pipeline("backdropVertex", "backdropTexturedFragment",
                                      depth: depthFormat),
              let plain = pipeline("backdropVertex", "backdropPlainFragment",
                                   depth: depthFormat),
              let composite = pipeline("compositeVertex", "compositeFragment",
                                       depth: .invalid) else { return nil }

        let descriptor = MTLDepthStencilDescriptor()
        // `SplatSceneCoordinator.perspective` lägger nära planet på 0 och
        // fjärran på 1 — vanligt djup, inte omvänt. Med `.greater` och en
        // buffert rensad till noll vann i stället den BORTERSTA ytan, så
        // bakgrunden ritade fjärrväggen ovanpå närväggen och gav ett smetigt
        // rum ur alla vinklar.
        descriptor.depthCompareFunction = .less
        descriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: descriptor) else { return nil }

        texturedPipeline = textured
        plainPipeline = plain
        compositePipeline = composite
        self.depthState = depthState
    }

    // MARK: - Ytan

    /// Lägger in ytan att rita. Utan `textureURL` blir den enfärgad.
    ///
    /// Atlasen läses RÅ, inte som sRGB. Splattens färger matas också in råa —
    /// se `matchingTraining` — och de två måste hamna i samma rum, annars ligger
    /// bakgrunden synligt ljusare än splatten framför den.
    func load(_ mesh: TexturedMesh, textureURL: URL?) {
        guard !mesh.isEmpty,
              mesh.normals.count == mesh.positions.count,
              mesh.textureCoordinates.count == mesh.positions.count else { return }

        positions = buffer(mesh.positions)
        normals = buffer(mesh.normals)
        coordinates = buffer(mesh.textureCoordinates)
        indices = buffer(mesh.indices)
        indexCount = mesh.indices.count

        if let textureURL {
            atlas = try? MTKTextureLoader(device: device).newTexture(
                URL: textureURL,
                options: [.SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue])
        }
    }

    private func buffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { raw in
            guard let base = raw.baseAddress, !raw.isEmpty else { return nil }
            return device.makeBuffer(bytes: base, length: raw.count, options: .storageModeShared)
        }
    }

    // MARK: - Ritningen

    /// Rutan splatten ska rita i, i rätt storlek. `nil` när den inte gick att
    /// skapa — då ritas splatten direkt i bilden som förr.
    func splatTarget(size: CGSize, format: MTLPixelFormat) -> MTLTexture? {
        let width = Int(size.width), height = Int(size.height)
        guard width > 0, height > 0 else { return nil }
        if let splatTexture, splatTexture.width == width, splatTexture.height == height {
            return splatTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        splatTexture = device.makeTexture(descriptor: descriptor)
        return splatTexture
    }

    /// Ritar ytan i bilden. Djupet rensas till ett och jämförs med `less` —
    /// samma vanliga djup som projektionen i `SplatSceneCoordinator` ger.
    func drawMesh(into commands: MTLCommandBuffer,
                  color: MTLTexture,
                  depth: MTLTexture?,
                  viewProjection: simd_float4x4,
                  eye: SIMD3<Float>) {
        guard isReady,
              let positions, let normals, let coordinates, let indices else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        if let depth {
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .clear
            pass.depthAttachment.storeAction = .dontCare
            pass.depthAttachment.clearDepth = 1
        }

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(atlas == nil ? plainPipeline : texturedPipeline)
        if depth != nil { encoder.setDepthStencilState(depthState) }
        // Rummet ses inifrån, så baksidorna är just de som vetter mot kameran.
        encoder.setCullMode(.none)

        var uniforms = Uniforms(viewProjection: viewProjection, eye: eye, tint: Self.plainTint)
        encoder.setVertexBuffer(positions, offset: 0, index: 0)
        encoder.setVertexBuffer(normals, offset: 0, index: 1)
        encoder.setVertexBuffer(coordinates, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        if let atlas { encoder.setFragmentTexture(atlas, index: 0) }

        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indices,
                                      indexBufferOffset: 0)
        encoder.endEncoding()
    }

    /// Lägger splattens ruta över det som redan ritats. Färgbufferten LADDAS,
    /// inte rensas — hopfogningen läser ytan under sig ur den.
    func composite(_ splats: MTLTexture,
                   into commands: MTLCommandBuffer,
                   color: MTLTexture,
                   storeAction: MTLStoreAction) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .load
        pass.colorAttachments[0].storeAction = storeAction

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(splats, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }
}
