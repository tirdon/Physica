// MetalRenderer — the native `RenderBackend`, a Metal port of the WebGPU
// renderer (`Sources/WASM/Renderer/WebGPURenderer`). Same pass structure:
// stencil-then-cover path fills (nonzero winding), CPU-expanded stroke quads
// blended write-once via stencil, Lambert/toon meshes with an inverted-hull
// outline, textured sprite/image quads. 4× MSAA; buffers rebuilt per frame.
//
// One set of pipelines serves both targets: onscreen it renders into an MTKView
// drawable (`render(_:)`, the RenderBackend witness the Engine calls each tick),
// offscreen it renders into a private texture and reads back a CGImage
// (`image(of:width:height:)`, the headless smoke path). WebGPU and Metal share
// [0,1] NDC depth and a top-left framebuffer origin, so the camera matrices and
// winding carry over — the one fixup is Metal's default front-facing winding is
// clockwise, so we set it counterClockwise to match WebGPU's default (our
// UV-grid meshes wind outward faces CW → "back", which the outline pass culls).

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(macOS)
import Metal
import MetalKit
import CoreGraphics
import CoreText
import Foundation

@MainActor
public final class MetalRenderer: RenderBackend {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let library: MTLLibrary

    // Pipelines + their depth/stencil companions (WebGPU bundles these; Metal
    // splits the render pipeline state from the depth-stencil state).
    private let stencilPSO, coverPSO, strokePSO, strokeClearPSO: MTLRenderPipelineState
    private let meshPSO, outlinePSO, spritePSO: MTLRenderPipelineState
    private let stencilDS, coverDS, strokeDS, strokeClearDS: MTLDepthStencilState
    private let meshDS, outlineDS, spriteDS: MTLDepthStencilState
    private let sampler: MTLSamplerState

    /// Bitmap caches, mirroring the WebGPU sprite cache: emoji clusters
    /// rasterize synchronously with CoreText; URLs (file / data: / http) load
    /// asynchronously and the quad skips frames until the decode lands.
    private var emojiTextures: [String: MTLTexture?] = [:]
    private var urlTextures: [String: URLTextureState] = [:]
    private var textLabelTextures: [String: MTLTexture?] = [:]

    private enum URLTextureState {
        case loading
        case ready(MTLTexture)
        case failed
    }

    /// Onscreen: the MTKView whose drawable this frame renders into (set by
    /// `AppRuntime` before each `engine.tick`). nil on the offscreen path.
    var currentView: MTKView?

    /// Current target size (drawable or offscreen), for the projected aspect.
    private var targetWidth = 1280
    private var targetHeight = 800

    public var aspectRatio: Real {
        targetHeight > 0 ? Real(targetWidth) / Real(targetHeight) : 1.6
    }

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.queue = queue
        // Bind to a local so the pipeline/state helpers below capture `library`
        // and the `device` parameter — not `self` — before every stored
        // property is initialized (definite-initialization).
        let library = try device.makeLibrary(source: MetalShaders.source, options: nil)
        self.library = library

        // Vertex layouts: flat = float3 position (stride 12); mesh = float3
        // position + float3 normal (stride 24).
        let flatVD = MTLVertexDescriptor()
        flatVD.attributes[0].format = .float3
        flatVD.attributes[0].offset = 0
        flatVD.attributes[0].bufferIndex = 0
        flatVD.layouts[0].stride = 12

        let meshVD = MTLVertexDescriptor()
        meshVD.attributes[0].format = .float3
        meshVD.attributes[0].offset = 0
        meshVD.attributes[0].bufferIndex = 0
        meshVD.attributes[1].format = .float3
        meshVD.attributes[1].offset = 12
        meshVD.attributes[1].bufferIndex = 0
        meshVD.layouts[0].stride = 24

        func pipeline(
            _ vertex: String, _ fragment: String, vertexDescriptor: MTLVertexDescriptor,
            blend: Bool, writeColor: Bool = true
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.vertexDescriptor = vertexDescriptor
            descriptor.rasterSampleCount = 4
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = .bgra8Unorm
            color.writeMask = writeColor ? .all : []
            if blend {
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .one
                color.sourceAlphaBlendFactor = .one
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            descriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
            descriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        stencilPSO = try pipeline("vs_flat", "fs_color", vertexDescriptor: flatVD, blend: false, writeColor: false)
        coverPSO = try pipeline("vs_flat", "fs_color", vertexDescriptor: flatVD, blend: true)
        strokePSO = try pipeline("vs_flat", "fs_color", vertexDescriptor: flatVD, blend: true)
        strokeClearPSO = try pipeline("vs_flat", "fs_color", vertexDescriptor: flatVD, blend: false, writeColor: false)
        spritePSO = try pipeline("vs_sprite", "fs_sprite", vertexDescriptor: flatVD, blend: true)
        meshPSO = try pipeline("vs_mesh", "fs_mesh", vertexDescriptor: meshVD, blend: true)
        outlinePSO = try pipeline("vs_outline", "fs_outline", vertexDescriptor: meshVD, blend: true)

        func face(
            compare: MTLCompareFunction, pass: MTLStencilOperation,
            fail: MTLStencilOperation = .keep, depthFail: MTLStencilOperation = .keep
        ) -> MTLStencilDescriptor {
            let stencil = MTLStencilDescriptor()
            stencil.stencilCompareFunction = compare
            stencil.depthStencilPassOperation = pass
            stencil.stencilFailureOperation = fail
            stencil.depthFailureOperation = depthFail
            stencil.readMask = 0xFF
            stencil.writeMask = 0xFF
            return stencil
        }
        func depthStencil(
            depthWrite: Bool, compare: MTLCompareFunction,
            front: MTLStencilDescriptor, back: MTLStencilDescriptor
        ) -> MTLDepthStencilState {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.isDepthWriteEnabled = depthWrite
            descriptor.depthCompareFunction = compare
            descriptor.frontFaceStencil = front
            descriptor.backFaceStencil = back
            return device.makeDepthStencilState(descriptor: descriptor)!
        }

        // Pass A: winding into the stencil, no color.
        stencilDS = depthStencil(
            depthWrite: false, compare: .always,
            front: face(compare: .always, pass: .incrementWrap),
            back: face(compare: .always, pass: .decrementWrap)
        )
        // Pass B: cover fills where stencil != 0 and zeroes it for the next path.
        coverDS = depthStencil(
            depthWrite: false, compare: .always,
            front: face(compare: .notEqual, pass: .zero, fail: .zero),
            back: face(compare: .notEqual, pass: .zero, fail: .zero)
        )
        // Strokes blend write-once: draw where stencil == 0 and bump it…
        strokeDS = depthStencil(
            depthWrite: false, compare: .always,
            front: face(compare: .equal, pass: .incrementClamp),
            back: face(compare: .equal, pass: .incrementClamp)
        )
        // …then a color-masked re-draw of the same range zeroes the marks.
        strokeClearDS = depthStencil(
            depthWrite: false, compare: .always,
            front: face(compare: .always, pass: .zero),
            back: face(compare: .always, pass: .zero)
        )
        let keep = face(compare: .always, pass: .keep)
        meshDS = depthStencil(depthWrite: true, compare: .less, front: keep, back: keep)
        outlineDS = depthStencil(depthWrite: true, compare: .less, front: keep, back: keep)
        spriteDS = depthStencil(depthWrite: false, compare: .always, front: keep, back: keep)

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)!
    }

    // MARK: Onscreen (RenderBackend witness)

    public func render(_ snapshot: SceneSnapshot) {
        guard let view = currentView,
              let passDescriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = queue.makeCommandBuffer()
        else { return }
        let size = view.drawableSize
        targetWidth = Int(size.width)
        targetHeight = Int(size.height)
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .multisampleResolve
        passDescriptor.colorAttachments[0].clearColor = clearColor(snapshot.background)
        encode(snapshot, passDescriptor: passDescriptor, commandBuffer: commandBuffer)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Offscreen (headless smoke)

    /// Renders one frame into a private texture and reads back a CGImage.
    /// Shares every pipeline with the onscreen path.
    public func image(of snapshot: SceneSnapshot, width: Int, height: Int) -> CGImage? {
        targetWidth = width
        targetHeight = height

        func texture(_ format: MTLPixelFormat, sampleCount: Int) -> MTLTexture? {
            let descriptor = MTLTextureDescriptor()
            descriptor.textureType = sampleCount > 1 ? .type2DMultisample : .type2D
            descriptor.pixelFormat = format
            descriptor.width = width
            descriptor.height = height
            descriptor.sampleCount = sampleCount
            descriptor.storageMode = .private
            descriptor.usage = .renderTarget
            return device.makeTexture(descriptor: descriptor)
        }
        guard let msaa = texture(.bgra8Unorm, sampleCount: 4),
              let resolve = texture(.bgra8Unorm, sampleCount: 1),
              let depth = texture(.depth32Float_stencil8, sampleCount: 4),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let commandBuffer = queue.makeCommandBuffer()
        else { return nil }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = msaa
        passDescriptor.colorAttachments[0].resolveTexture = resolve
        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .multisampleResolve
        passDescriptor.colorAttachments[0].clearColor = clearColor(snapshot.background)
        passDescriptor.depthAttachment.texture = depth
        passDescriptor.depthAttachment.loadAction = .clear
        passDescriptor.depthAttachment.clearDepth = 1
        passDescriptor.depthAttachment.storeAction = .dontCare
        passDescriptor.stencilAttachment.texture = depth
        passDescriptor.stencilAttachment.loadAction = .clear
        passDescriptor.stencilAttachment.clearStencil = 0
        passDescriptor.stencilAttachment.storeAction = .dontCare

        encode(snapshot, passDescriptor: passDescriptor, commandBuffer: commandBuffer)

        // Copy the resolved (single-sample) target into a shared buffer — a
        // blit works on every macOS GPU, unlike reading a texture directly.
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: resolve, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: readback, destinationOffset: 0,
            destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4
        )
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return cgImage(fromBGRA: readback, width: width, height: height)
    }

    // MARK: Encoding (shared)

    private func encode(
        _ snapshot: SceneSnapshot, passDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        let packet = GeometryUploader.pack(snapshot)
        let flatBuffer = makeBuffer(packet.flatVertices)
        let meshBuffer = makeBuffer(packet.meshVertices)
        let indexBuffer = makeBuffer(packet.meshIndices)
        let uniformBuffer = makeBuffer(packet.uniforms)

        let viewProjection = snapshot.camera.projection * snapshot.camera.view
        let globals = viewProjection.floatArray

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else { return }
        // Match WebGPU's default ccw front face so our CW-outward meshes cull as
        // "back" in the outline pass. Reference 0 for the write-once stroke test.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setStencilReferenceValue(0)
        encoder.setVertexBytes(globals, length: 64, index: 1)

        for command in packet.commands {
            switch command.kind {
            case .mesh, .meshOutline:
                guard let meshBuffer, let indexBuffer else { continue }
                encoder.setRenderPipelineState(command.kind == .mesh ? meshPSO : outlinePSO)
                encoder.setDepthStencilState(command.kind == .mesh ? meshDS : outlineDS)
                encoder.setCullMode(command.kind == .meshOutline ? .back : .none)
                encoder.setVertexBuffer(meshBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                encoder.setFragmentBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                encoder.drawIndexedPrimitives(
                    type: .triangle, indexCount: command.indexCount, indexType: .uint32,
                    indexBuffer: indexBuffer, indexBufferOffset: command.indexStart * 4,
                    instanceCount: 1, baseVertex: command.baseVertex, baseInstance: 0
                )
                if command.kind == .meshOutline { encoder.setCullMode(.none) }

            case .pathStencil, .pathCover, .stroke:
                guard let flatBuffer else { continue }
                let pipeline: MTLRenderPipelineState
                let depthStencil: MTLDepthStencilState
                switch command.kind {
                case .pathStencil: (pipeline, depthStencil) = (stencilPSO, stencilDS)
                case .pathCover: (pipeline, depthStencil) = (coverPSO, coverDS)
                default: (pipeline, depthStencil) = (strokePSO, strokeDS)
                }
                encoder.setRenderPipelineState(pipeline)
                encoder.setDepthStencilState(depthStencil)
                encoder.setVertexBuffer(flatBuffer, offset: 0, index: 0)
                encoder.setVertexBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                encoder.setFragmentBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                encoder.drawPrimitives(
                    type: .triangle, vertexStart: command.vertexStart, vertexCount: command.vertexCount
                )
                if command.kind == .stroke {
                    encoder.setRenderPipelineState(strokeClearPSO)
                    encoder.setDepthStencilState(strokeClearDS)
                    encoder.drawPrimitives(
                        type: .triangle, vertexStart: command.vertexStart, vertexCount: command.vertexCount
                    )
                }

            case .sprite, .image:
                guard let flatBuffer, let source = command.texture,
                      let texture = resolveTexture(source) else { continue }
                encoder.setRenderPipelineState(spritePSO)
                encoder.setDepthStencilState(spriteDS)
                // Bind the flat stream at the quad's byte offset so vertex_id
                // runs 0..5 over the shader's UV table.
                encoder.setVertexBuffer(flatBuffer, offset: command.vertexStart * 12, index: 0)
                encoder.setVertexBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                encoder.setFragmentBuffer(uniformBuffer, offset: command.uniformOffset, index: 2)
                var texAspect = Float(texture.width) / Float(max(texture.height, 1))
                encoder.setFragmentBytes(&texAspect, length: 4, index: 3)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }

        // Shift debug overlay (screen labels): small CoreText-rasterized quads,
        // colored by interaction kind on the Option+Shift variant. Empty unless
        // the engine flagged the overlay active this frame.
        drawDebugLabels(snapshot.debugLabels, encoder: encoder, uniformBuffer: uniformBuffer)

        encoder.endEncoding()
    }

    private func makeBuffer<T>(_ array: [T]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        return array.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }

    private func clearColor(_ background: SceneBackground) -> MTLClearColor {
        // Premultiplied, matching the WebGPU renderer and the premultiplied blend.
        let color = background.baseColor
        return MTLClearColor(
            red: Double(color.r * color.a), green: Double(color.g * color.a),
            blue: Double(color.b * color.a), alpha: Double(color.a)
        )
    }

    // MARK: Textures

    private func resolveTexture(_ source: TextureSource) -> MTLTexture? {
        switch source {
        case .emoji(let cluster):
            if let cached = emojiTextures[cluster] { return cached }
            let texture = rasterizeEmoji(cluster)
            emojiTextures[cluster] = texture
            return texture
        case .url(let url):
            switch urlTextures[url] {
            case .ready(let texture): return texture
            case .loading, .failed: return nil
            case nil:
                loadURLTexture(url)
                return nil
            }
        }
    }

    /// Fetch → decode → upload, once per URL. Supports file paths, `data:`
    /// URIs, and http(s) (a simple URLSession fetch). Failures warn once and
    /// park as `.failed`; frames skip the quad either way — mirrors the WebGPU
    /// sprite cache semantics.
    private func loadURLTexture(_ url: String) {
        guard urlTextures[url] == nil else { return }
        urlTextures[url] = .loading
        Task { @MainActor [weak self] in
            guard let self else { return }
            let data = await Self.fetchData(url)
            guard let data,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let texture = self.texture(from: cgImage)
            else {
                self.urlTextures[url] = .failed
                FileHandle.standardError.write(Data("Physica: bitmap failed — \(url)\n".utf8))
                return
            }
            self.urlTextures[url] = .ready(texture)
        }
    }

    private static func fetchData(_ url: String) async -> Data? {
        if url.hasPrefix("data:") {
            guard let comma = url.firstIndex(of: ","), url[..<comma].contains(";base64") else { return nil }
            let base64 = String(url[url.index(after: comma)...])
            return Data(base64Encoded: base64)
        }
        if let parsed = URL(string: url), let scheme = parsed.scheme,
           scheme == "http" || scheme == "https" {
            return try? await URLSession.shared.data(from: parsed).0
        }
        // Bare path or file:// URL.
        let path = url.hasPrefix("file://") ? (URL(string: url)?.path ?? url) : url
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// Rasterizes an emoji cluster with CoreText (color glyphs via CTLineDraw)
    /// into a square premultiplied texture.
    private func rasterizeEmoji(_ cluster: String) -> MTLTexture? {
        let side = 128
        let font = CTFontCreateWithName("Apple Color Emoji" as CFString, CGFloat(side) * 0.82, nil)
        let attributes = [kCTFontAttributeName: font] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, cluster as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        guard let context = bitmapContext(width: side, height: side) else { return nil }
        let bounds = CTLineGetImageBounds(line, context)
        context.textPosition = CGPoint(
            x: (CGFloat(side) - bounds.width) / 2 - bounds.minX,
            y: (CGFloat(side) - bounds.height) / 2 - bounds.minY
        )
        CTLineDraw(line, context)
        return context.makeImage().flatMap { texture(from: $0) }
    }

    /// Rasterizes a debug label string (system font) in `color`.
    private func rasterizeLabel(_ text: String, color: Color) -> MTLTexture? {
        let fontSize: CGFloat = 44
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let cgColor = CGColor(
            srgbRed: CGFloat(color.r), green: CGFloat(color.g), blue: CGFloat(color.b), alpha: 1
        )
        let attributes = [
            kCTFontAttributeName: font, kCTForegroundColorAttributeName: cgColor,
        ] as CFDictionary
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes) else { return nil }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let padding: CGFloat = 8
        let pixelsWide = max(Int((width + padding * 2).rounded(.up)), 1)
        let pixelsHigh = max(Int((ascent + descent + padding * 2).rounded(.up)), 1)
        guard let context = bitmapContext(width: pixelsWide, height: pixelsHigh) else { return nil }
        context.textPosition = CGPoint(x: padding, y: padding + descent)
        CTLineDraw(line, context)
        return context.makeImage().flatMap { texture(from: $0) }
    }

    private func bitmapContext(width: Int, height: Int) -> CGContext? {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// CGImage → premultiplied rgba8 MTLTexture. A CGBitmapContext is already
    /// top-down (memory row 0 = the visual top), and `draw` maps the source
    /// image's top row there, so texel v = 0 lands on the quad's top-left corner
    /// (uv (0,0)) — no CTM flip. Flipping the context here double-inverts and
    /// renders every textured quad (labels, sprites, images, emoji) upside down.
    /// `internal` so `TextureOrientationTests` can lock the row-0 = visual-top
    /// contract that the whole textured-quad path depends on.
    func texture(from cgImage: CGImage) -> MTLTexture? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }
        let bytesPerRow = width * 4
        let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerRow * height, alignment: 4)
        defer { data.deallocate() }
        guard let context = CGContext(
            data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: data, bytesPerRow: bytesPerRow
        )
        return texture
    }

    private func cgImage(fromBGRA buffer: MTLBuffer, width: Int, height: Int) -> CGImage? {
        let length = width * height * 4
        let copy = Data(bytes: buffer.contents(), count: length)
        guard let provider = CGDataProvider(data: copy as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: Debug labels

    private func drawDebugLabels(
        _ labels: [DebugLabel], encoder: MTLRenderCommandEncoder, uniformBuffer: MTLBuffer?
    ) {
        guard !labels.isEmpty else { return }
        let worldHeight: Real = 0.34
        encoder.setRenderPipelineState(spritePSO)
        encoder.setDepthStencilState(spriteDS)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for label in labels {
            let color = labelColor(label.interaction)
            let key = "\(label.text)#\(color.r),\(color.g),\(color.b)"
            let texture: MTLTexture?
            if let cached = textLabelTextures[key] {
                texture = cached
            } else {
                texture = rasterizeLabel(label.text, color: color)
                textLabelTextures[key] = texture
            }
            guard let texture else { continue }
            let aspect = Float(texture.width) / Float(max(texture.height, 1))
            let halfHeight = worldHeight / 2
            let halfWidth = halfHeight * Real(aspect)
            let center = label.worldPosition
            // Two triangles (TL BL BR, TL BR TR) matching the sprite UV table.
            let corners: [Float32] = [
                Float32(center.x - halfWidth), Float32(center.y + halfHeight), Float32(center.z),
                Float32(center.x - halfWidth), Float32(center.y - halfHeight), Float32(center.z),
                Float32(center.x + halfWidth), Float32(center.y - halfHeight), Float32(center.z),
                Float32(center.x - halfWidth), Float32(center.y + halfHeight), Float32(center.z),
                Float32(center.x + halfWidth), Float32(center.y - halfHeight), Float32(center.z),
                Float32(center.x + halfWidth), Float32(center.y + halfHeight), Float32(center.z),
            ]
            // Uniform slot: identity model, white (opacity 1), params.x = aspect.
            var uniforms = [Float32](repeating: 0, count: 24)
            uniforms[0] = 1; uniforms[5] = 1; uniforms[10] = 1; uniforms[15] = 1  // identity
            uniforms[16] = 1; uniforms[17] = 1; uniforms[18] = 1; uniforms[19] = 1  // white
            uniforms[20] = aspect
            encoder.setVertexBytes(corners, length: corners.count * 4, index: 0)
            encoder.setVertexBytes(uniforms, length: uniforms.count * 4, index: 2)
            encoder.setFragmentBytes(uniforms, length: uniforms.count * 4, index: 2)
            var texAspect = aspect
            encoder.setFragmentBytes(&texAspect, length: 4, index: 3)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    private func labelColor(_ kind: InteractionKind?) -> Color {
        switch kind {
        case .none: return .white
        case .drag: return .blue
        case .drop: return .green
        case .tap: return .yellow
        case .doubleClick: return .orange
        case .hover: return .teal
        }
    }
}

public enum RendererError: Error {
    case commandQueueUnavailable
}
#endif
