// WebGPURenderer — Swift-side WebGPU via JavaScriptKit JSObject calls.
//
// Path fills use stencil-then-cover (two passes; correct for concave shapes and
// holes via nonzero winding), strokes are CPU-expanded quads, meshes are Lambert.
// 4× MSAA throughout; one render pass per frame; buffers rebuilt per frame.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop

/// One sprite bitmap's lifecycle in the renderer's URL-keyed cache: decode in
/// flight, ready (its group-2 bind group: texture view + sampler + aspect), or
/// failed (warned once, never retried).
private enum SpriteTextureState {
    case loading
    case ready(JSValue)
    case failed
}

@MainActor
final class WebGPURenderer: RenderBackend {
    private let canvas: JSValue
    private let device: JSValue
    private let context: JSValue
    private let format: JSValue

    private var stencilPipeline: JSValue = .undefined
    private var coverPipeline: JSValue = .undefined
    private var strokePipeline: JSValue = .undefined
    private var meshPipeline: JSValue = .undefined
    private var outlinePipeline: JSValue = .undefined
    private var spritePipeline: JSValue = .undefined
    private var spriteBindGroupLayout: JSValue = .undefined
    private var spriteSampler: JSValue = .undefined
    private var spriteTextures: [String: SpriteTextureState] = [:]

    private var globalsBuffer: JSValue = .undefined
    private var globalsBindGroup: JSValue = .undefined
    private var drawBindGroupLayout: JSValue = .undefined

    private var msaaView: JSValue = .undefined
    private var depthView: JSValue = .undefined

    private var flatBuffer = GrowableBuffer(usageBits: GPU.vertex | GPU.copyDst)
    private var meshBuffer = GrowableBuffer(usageBits: GPU.vertex | GPU.copyDst)
    private var indexBuffer = GrowableBuffer(usageBits: GPU.index | GPU.copyDst)
    private var uniformBuffer = GrowableBuffer(usageBits: GPU.uniform | GPU.copyDst)
    private var drawBindGroup: JSValue = .undefined

    private var width = 0
    private var height = 0

    /// DOM overlay for image glyphs (emoji) — set by the web runtimes; synced
    /// each frame with the view-projection this renderer draws with.
    var emojiLayer: EmojiLayer?

    var aspectRatio: Real {
        height > 0 ? Real(width) / Real(height) : 1.6
    }

    // MARK: Setup

    static func create(canvasID: String) async throws -> WebGPURenderer {
        let global = JSObject.global
        let navigator: JSValue = global.navigator
        let gpu: JSValue = navigator.gpu
        guard !gpu.isUndefined else {
            throw RendererError.webGPUUnavailable
        }
        let adapter = try await JSPromise(unsafelyWrapping: gpu.requestAdapter().object!).value()
        guard !adapter.isNull else { throw RendererError.noAdapter }
        let device = try await JSPromise(unsafelyWrapping: adapter.requestDevice().object!).value()
        let canvas: JSValue = global.document.getElementById(canvasID)
        guard !canvas.isNull else { throw RendererError.canvasNotFound(canvasID) }
        return WebGPURenderer(canvas: canvas, device: device, gpu: gpu)
    }

    private init(canvas: JSValue, device: JSValue, gpu: JSValue) {
        self.canvas = canvas
        self.device = device
        self.context = canvas.getContext("webgpu")
        self.format = gpu.getPreferredCanvasFormat()

        let configuration: [String: JSValue] = [
            "device": device,
            "format": format,
            "alphaMode": "premultiplied",
        ]
        _ = context.configure(configuration.jsValue)

        buildPipelines()
        resizeIfNeeded()
    }

    private func buildPipelines() {
        let module = device.createShaderModule(["code": JSValue.string(Shaders.module)].jsValue)

        let globalsLayout = device.createBindGroupLayout([
            "entries": [
                [
                    "binding": JSValue.number(0),
                    "visibility": JSValue.number(Double(GPU.vertexStage | GPU.fragmentStage)),
                    "buffer": ["type": JSValue.string("uniform")].jsValue,
                ].jsValue
            ].jsValue
        ].jsValue)

        drawBindGroupLayout = device.createBindGroupLayout([
            "entries": [
                [
                    "binding": JSValue.number(0),
                    "visibility": JSValue.number(Double(GPU.vertexStage | GPU.fragmentStage)),
                    "buffer": [
                        "type": JSValue.string("uniform"),
                        "hasDynamicOffset": JSValue.boolean(true),
                        "minBindingSize": JSValue.number(96),
                    ].jsValue,
                ].jsValue
            ].jsValue
        ].jsValue)

        let layout = device.createPipelineLayout([
            "bindGroupLayouts": [globalsLayout, drawBindGroupLayout].jsValue
        ].jsValue)

        // Sprites add a third group: per-URL texture + shared sampler + the
        // texture's aspect (contain-fit). Built once per bitmap at load time.
        spriteBindGroupLayout = device.createBindGroupLayout([
            "entries": [
                [
                    "binding": JSValue.number(0),
                    "visibility": JSValue.number(Double(GPU.fragmentStage)),
                    "texture": [
                        "sampleType": JSValue.string("float"),
                        "viewDimension": JSValue.string("2d"),
                    ].jsValue,
                ].jsValue,
                [
                    "binding": JSValue.number(1),
                    "visibility": JSValue.number(Double(GPU.fragmentStage)),
                    "sampler": ["type": JSValue.string("filtering")].jsValue,
                ].jsValue,
                [
                    "binding": JSValue.number(2),
                    "visibility": JSValue.number(Double(GPU.fragmentStage)),
                    "buffer": [
                        "type": JSValue.string("uniform"),
                        "minBindingSize": JSValue.number(16),
                    ].jsValue,
                ].jsValue,
            ].jsValue
        ].jsValue)
        let spriteLayout = device.createPipelineLayout([
            "bindGroupLayouts": [globalsLayout, drawBindGroupLayout, spriteBindGroupLayout].jsValue
        ].jsValue)
        spriteSampler = device.createSampler([
            "magFilter": JSValue.string("linear"),
            "minFilter": JSValue.string("linear"),
        ].jsValue)

        let flatVertexBuffers: JSValue = [
            [
                "arrayStride": JSValue.number(12),
                "attributes": [
                    [
                        "shaderLocation": JSValue.number(0),
                        "offset": JSValue.number(0),
                        "format": JSValue.string("float32x3"),
                    ].jsValue
                ].jsValue,
            ].jsValue
        ].jsValue

        let meshVertexBuffers: JSValue = [
            [
                "arrayStride": JSValue.number(24),
                "attributes": [
                    [
                        "shaderLocation": JSValue.number(0),
                        "offset": JSValue.number(0),
                        "format": JSValue.string("float32x3"),
                    ].jsValue,
                    [
                        "shaderLocation": JSValue.number(1),
                        "offset": JSValue.number(12),
                        "format": JSValue.string("float32x3"),
                    ].jsValue,
                ].jsValue,
            ].jsValue
        ].jsValue

        let premultipliedBlend: JSValue = [
            "color": [
                "srcFactor": JSValue.string("one"),
                "dstFactor": JSValue.string("one-minus-src-alpha"),
                "operation": JSValue.string("add"),
            ].jsValue,
            "alpha": [
                "srcFactor": JSValue.string("one"),
                "dstFactor": JSValue.string("one-minus-src-alpha"),
                "operation": JSValue.string("add"),
            ].jsValue,
        ].jsValue

        func target(blend: Bool, writeMask: Int = 0xF) -> JSValue {
            var dict: [String: JSValue] = [
                "format": format,
                "writeMask": JSValue.number(Double(writeMask)),
            ]
            if blend { dict["blend"] = premultipliedBlend }
            return dict.jsValue
        }

        func stencilFace(compare: String, passOp: String, failOp: String = "keep") -> JSValue {
            [
                "compare": JSValue.string(compare),
                "passOp": JSValue.string(passOp),
                "failOp": JSValue.string(failOp),
                "depthFailOp": JSValue.string("keep"),
            ].jsValue
        }

        func depthStencil(
            depthWrite: Bool, depthCompare: String, front: JSValue, back: JSValue
        ) -> JSValue {
            [
                "format": JSValue.string("depth24plus-stencil8"),
                "depthWriteEnabled": JSValue.boolean(depthWrite),
                "depthCompare": JSValue.string(depthCompare),
                "stencilFront": front,
                "stencilBack": back,
                "stencilReadMask": JSValue.number(0xFF),
                "stencilWriteMask": JSValue.number(0xFF),
            ].jsValue
        }

        func pipeline(
            vertexEntry: String, fragmentEntry: String, buffers: JSValue,
            target: JSValue, depthStencil: JSValue, cullMode: String = "none",
            overrideLayout: JSValue? = nil
        ) -> JSValue {
            device.createRenderPipeline([
                "layout": overrideLayout ?? layout,
                "vertex": [
                    "module": module,
                    "entryPoint": JSValue.string(vertexEntry),
                    "buffers": buffers,
                ].jsValue,
                "fragment": [
                    "module": module,
                    "entryPoint": JSValue.string(fragmentEntry),
                    "targets": [target].jsValue,
                ].jsValue,
                "primitive": [
                    "topology": JSValue.string("triangle-list"),
                    "cullMode": JSValue.string(cullMode),
                ].jsValue,
                "depthStencil": depthStencil,
                "multisample": ["count": JSValue.number(4)].jsValue,
            ].jsValue)
        }

        // Pass A: winding into the stencil, no color.
        stencilPipeline = pipeline(
            vertexEntry: "vs_flat", fragmentEntry: "fs_color", buffers: flatVertexBuffers,
            target: target(blend: false, writeMask: 0),
            depthStencil: depthStencil(
                depthWrite: false, depthCompare: "always",
                front: stencilFace(compare: "always", passOp: "increment-wrap"),
                back: stencilFace(compare: "always", passOp: "decrement-wrap")
            )
        )

        // Pass B: cover quad fills where stencil != 0 and zeroes it for the next path.
        coverPipeline = pipeline(
            vertexEntry: "vs_flat", fragmentEntry: "fs_color", buffers: flatVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: false, depthCompare: "always",
                front: stencilFace(compare: "not-equal", passOp: "zero", failOp: "zero"),
                back: stencilFace(compare: "not-equal", passOp: "zero", failOp: "zero")
            )
        )

        strokePipeline = pipeline(
            vertexEntry: "vs_flat", fragmentEntry: "fs_color", buffers: flatVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: false, depthCompare: "always",
                front: stencilFace(compare: "always", passOp: "keep"),
                back: stencilFace(compare: "always", passOp: "keep")
            )
        )

        // Sprite quads: stroke-family settings (blend on, depth read-only) —
        // 2D painter's order, occludable by later paths in draw order.
        spritePipeline = pipeline(
            vertexEntry: "vs_sprite", fragmentEntry: "fs_sprite", buffers: flatVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: false, depthCompare: "always",
                front: stencilFace(compare: "always", passOp: "keep"),
                back: stencilFace(compare: "always", passOp: "keep")
            ),
            overrideLayout: spriteLayout
        )

        meshPipeline = pipeline(
            vertexEntry: "vs_mesh", fragmentEntry: "fs_mesh", buffers: meshVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: true, depthCompare: "less",
                front: stencilFace(compare: "always", passOp: "keep"),
                back: stencilFace(compare: "always", passOp: "keep")
            )
        )

        // Toon outline: inflated hull with its camera-facing side culled, so
        // only the far shell survives the base mesh's depth test — a
        // silhouette ring. Our UV-grid meshes wind outward faces CW, which is
        // "back" under WebGPU's default ccw frontFace; the near side is
        // therefore culled with "back", not "front".
        outlinePipeline = pipeline(
            vertexEntry: "vs_outline", fragmentEntry: "fs_outline", buffers: meshVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: true, depthCompare: "less",
                front: stencilFace(compare: "always", passOp: "keep"),
                back: stencilFace(compare: "always", passOp: "keep")
            ),
            cullMode: "back"
        )

        globalsBuffer = device.createBuffer([
            "size": JSValue.number(64),
            "usage": JSValue.number(Double(GPU.uniform | GPU.copyDst)),
        ].jsValue)
        globalsBindGroup = device.createBindGroup([
            "layout": globalsLayout,
            "entries": [
                [
                    "binding": JSValue.number(0),
                    "resource": ["buffer": globalsBuffer].jsValue,
                ].jsValue
            ].jsValue,
        ].jsValue)
    }

    // MARK: Resize

    private func resizeIfNeeded() {
        let dpr = JSObject.global.devicePixelRatio.number ?? 1
        let clientWidth = canvas.clientWidth.number ?? 0
        let clientHeight = canvas.clientHeight.number ?? 0
        guard clientWidth > 0, clientHeight > 0 else { return }
        let targetWidth = Int((clientWidth * dpr).rounded())
        let targetHeight = Int((clientHeight * dpr).rounded())
        guard targetWidth != width || targetHeight != height else { return }

        width = targetWidth
        height = targetHeight
        canvas.width = .number(Double(targetWidth))
        canvas.height = .number(Double(targetHeight))

        func texture(format: JSValue, usageBits: Int) -> JSValue {
            device.createTexture([
                "size": [
                    "width": JSValue.number(Double(targetWidth)),
                    "height": JSValue.number(Double(targetHeight)),
                ].jsValue,
                "sampleCount": JSValue.number(4),
                "format": format,
                "usage": JSValue.number(Double(usageBits)),
            ].jsValue)
        }

        msaaView = texture(format: format, usageBits: GPU.renderAttachment).createView()
        depthView = texture(
            format: .string("depth24plus-stencil8"), usageBits: GPU.renderAttachment
        ).createView()
    }

    // MARK: Frame

    func render(_ snapshot: SceneSnapshot) {
        resizeIfNeeded()
        guard !msaaView.isUndefined else { return }

        let packet = GeometryUploader.pack(snapshot)
        uploadBuffers(packet)

        // Globals: projection (with live aspect) × view.
        let viewProjection = snapshot.camera.projection * snapshot.camera.view

        // Image glyphs (emoji) draw in the DOM emoji layer, projected with the
        // same matrices this frame renders with; the uploader skips them.
        emojiLayer?.sync(snapshot, viewProjection: viewProjection)
        _ = device.queue.writeBuffer(
            globalsBuffer, 0, JSTypedArray<Float32>(viewProjection.floatArray).jsValue
        )

        let background = snapshot.background.baseColor
        let clearColor: [String: JSValue] = [
            "r": .number(Double(background.r * background.a)),
            "g": .number(Double(background.g * background.a)),
            "b": .number(Double(background.b * background.a)),
            "a": .number(Double(background.a)),
        ]

        let encoder = device.createCommandEncoder()
        let pass = encoder.beginRenderPass([
            "colorAttachments": [
                [
                    "view": msaaView,
                    "resolveTarget": context.getCurrentTexture().createView(),
                    "clearValue": clearColor.jsValue,
                    "loadOp": JSValue.string("clear"),
                    "storeOp": JSValue.string("discard"),
                ].jsValue
            ].jsValue,
            "depthStencilAttachment": [
                "view": depthView,
                "depthClearValue": JSValue.number(1),
                "depthLoadOp": JSValue.string("clear"),
                "depthStoreOp": JSValue.string("discard"),
                "stencilClearValue": JSValue.number(0),
                "stencilLoadOp": JSValue.string("clear"),
                "stencilStoreOp": JSValue.string("discard"),
            ].jsValue,
        ].jsValue)

        _ = pass.setBindGroup(0, globalsBindGroup)

        var boundFlat = false
        var boundMesh = false
        for command in packet.commands {
            switch command.kind {
            case .mesh, .meshOutline:
                _ = pass.setPipeline(command.kind == .mesh ? meshPipeline : outlinePipeline)
                if !boundMesh {
                    _ = pass.setVertexBuffer(0, meshBuffer.buffer)
                    _ = pass.setIndexBuffer(indexBuffer.buffer, "uint32")
                    boundMesh = true
                }
                boundFlat = false
                _ = pass.setBindGroup(1, drawBindGroup, [command.uniformOffset].jsValue)
                _ = pass.drawIndexed(
                    command.indexCount, 1, command.indexStart, command.baseVertex, 0
                )
            case .pathStencil, .pathCover, .stroke:
                switch command.kind {
                case .pathStencil: _ = pass.setPipeline(stencilPipeline)
                case .pathCover: _ = pass.setPipeline(coverPipeline)
                default: _ = pass.setPipeline(strokePipeline)
                }
                if !boundFlat {
                    _ = pass.setVertexBuffer(0, flatBuffer.buffer)
                    boundFlat = true
                }
                boundMesh = false
                _ = pass.setBindGroup(1, drawBindGroup, [command.uniformOffset].jsValue)
                _ = pass.draw(command.vertexCount, 1, command.vertexStart, 0)
            case .sprite:
                guard let url = command.textureURL else { continue }
                switch spriteTextures[url] {
                case .ready(let textureGroup):
                    _ = pass.setPipeline(spritePipeline)
                    // Bind the flat stream at the quad's byte offset so
                    // vertex_index runs 0..5 for the shader's UV table.
                    _ = pass.setVertexBuffer(0, flatBuffer.buffer, command.vertexStart * 12)
                    boundFlat = false   // offset-bound; the next path rebinds at 0
                    boundMesh = false
                    _ = pass.setBindGroup(1, drawBindGroup, [command.uniformOffset].jsValue)
                    _ = pass.setBindGroup(2, textureGroup)
                    _ = pass.draw(6, 1, 0, 0)
                case nil:
                    // First sighting: start the decode; the quad draws once
                    // a later frame finds the texture ready.
                    ensureSpriteTexture(url)
                case .loading, .failed:
                    break
                }
            }
        }

        _ = pass.end()
        let commandBuffer: JSValue = encoder.finish()
        _ = device.queue.submit([commandBuffer].jsValue)
    }

    // MARK: Sprite textures

    /// Fetch → decode → upload, once per URL: createImageBitmap feeds
    /// copyExternalImageToTexture (premultiplied, matching the pass blend),
    /// and the group-2 bind group (view + sampler + aspect) is built once so
    /// per-frame sprite draws are pure bind-and-draw. Failures warn once and
    /// park as `.failed`; frames simply skip the quad either way.
    private func ensureSpriteTexture(_ url: String) {
        guard spriteTextures[url] == nil else { return }
        spriteTextures[url] = .loading
        Task { @MainActor [weak self] in
            let global = JSObject.global
            do {
                let response = try await JSPromise(
                    unsafelyWrapping: global.fetch!(url).object!
                ).value()
                let blob = try await JSPromise(
                    unsafelyWrapping: response.blob().object!
                ).value()
                let bitmap = try await JSPromise(
                    unsafelyWrapping: global.createImageBitmap!(blob).object!
                ).value()
                guard let self else { return }
                let width = max(bitmap.width.number ?? 1, 1)
                let height = max(bitmap.height.number ?? 1, 1)
                let texture = self.device.createTexture([
                    "size": [
                        "width": JSValue.number(width),
                        "height": JSValue.number(height),
                    ].jsValue,
                    "format": JSValue.string("rgba8unorm"),
                    "usage": JSValue.number(Double(
                        GPU.textureCopyDst | GPU.textureBinding | GPU.renderAttachment
                    )),
                ].jsValue)
                _ = self.device.queue.copyExternalImageToTexture(
                    ["source": bitmap].jsValue,
                    ["texture": texture, "premultipliedAlpha": JSValue.boolean(true)].jsValue,
                    ["width": JSValue.number(width), "height": JSValue.number(height)].jsValue
                )
                let aspectBuffer = self.device.createBuffer([
                    "size": JSValue.number(16),
                    "usage": JSValue.number(Double(GPU.uniform | GPU.copyDst)),
                ].jsValue)
                _ = self.device.queue.writeBuffer(
                    aspectBuffer, 0,
                    JSTypedArray<Float32>([Float32(width / height), 0, 0, 0]).jsValue
                )
                let bindGroup = self.device.createBindGroup([
                    "layout": self.spriteBindGroupLayout,
                    "entries": [
                        [
                            "binding": JSValue.number(0),
                            "resource": texture.createView(),
                        ].jsValue,
                        [
                            "binding": JSValue.number(1),
                            "resource": self.spriteSampler,
                        ].jsValue,
                        [
                            "binding": JSValue.number(2),
                            "resource": ["buffer": aspectBuffer].jsValue,
                        ].jsValue,
                    ].jsValue,
                ].jsValue)
                self.spriteTextures[url] = .ready(bindGroup)
            } catch {
                self?.spriteTextures[url] = .failed
                _ = global.console.warn(
                    "Physica: sprite bitmap failed —", url, String(describing: error)
                )
            }
        }
    }

    private func uploadBuffers(_ packet: FramePacket) {
        if !packet.flatVertices.isEmpty {
            flatBuffer.ensureCapacity(packet.flatVertices.count * 4, device: device)
            _ = device.queue.writeBuffer(
                flatBuffer.buffer, 0, JSTypedArray<Float32>(packet.flatVertices).jsValue
            )
        }
        if !packet.meshVertices.isEmpty {
            meshBuffer.ensureCapacity(packet.meshVertices.count * 4, device: device)
            _ = device.queue.writeBuffer(
                meshBuffer.buffer, 0, JSTypedArray<Float32>(packet.meshVertices).jsValue
            )
        }
        if !packet.meshIndices.isEmpty {
            indexBuffer.ensureCapacity(packet.meshIndices.count * 4, device: device)
            _ = device.queue.writeBuffer(
                indexBuffer.buffer, 0, JSTypedArray<UInt32>(packet.meshIndices).jsValue
            )
        }
        if !packet.uniforms.isEmpty {
            let grew = uniformBuffer.ensureCapacity(packet.uniforms.count * 4, device: device)
            if grew || drawBindGroup.isUndefined {
                drawBindGroup = device.createBindGroup([
                    "layout": drawBindGroupLayout,
                    "entries": [
                        [
                            "binding": JSValue.number(0),
                            "resource": [
                                "buffer": uniformBuffer.buffer,
                                "offset": JSValue.number(0),
                                "size": JSValue.number(96),
                            ].jsValue,
                        ].jsValue
                    ].jsValue,
                ].jsValue)
            }
            _ = device.queue.writeBuffer(
                uniformBuffer.buffer, 0, JSTypedArray<Float32>(packet.uniforms).jsValue
            )
        }
    }
}

#endif
