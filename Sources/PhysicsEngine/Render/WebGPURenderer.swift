// WebGPURenderer — Swift-side WebGPU via JavaScriptKit JSObject calls.
//
// Path fills use stencil-then-cover (two passes; correct for concave shapes and
// holes via nonzero winding), strokes are CPU-expanded quads, meshes are Lambert.
// 4× MSAA throughout; one render pass per frame; buffers rebuilt per frame.

#if os(WASI)
import JavaScriptKit
import Physica

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
            target: JSValue, depthStencil: JSValue
        ) -> JSValue {
            device.createRenderPipeline([
                "layout": layout,
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
                    "cullMode": JSValue.string("none"),
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

        meshPipeline = pipeline(
            vertexEntry: "vs_mesh", fragmentEntry: "fs_mesh", buffers: meshVertexBuffers,
            target: target(blend: true),
            depthStencil: depthStencil(
                depthWrite: true, depthCompare: "less",
                front: stencilFace(compare: "always", passOp: "keep"),
                back: stencilFace(compare: "always", passOp: "keep")
            )
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
        _ = device.queue.writeBuffer(
            globalsBuffer, 0, JSTypedArray<Float32>(viewProjection.floatArray).jsValue
        )

        let background = snapshot.background
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
            case .mesh:
                _ = pass.setPipeline(meshPipeline)
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
            }
        }

        _ = pass.end()
        let commandBuffer: JSValue = encoder.finish()
        _ = device.queue.submit([commandBuffer].jsValue)
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

enum RendererError: Error {
    case webGPUUnavailable
    case noAdapter
    case canvasNotFound(String)
}

/// Pow2-growing GPU buffer.
@MainActor
struct GrowableBuffer {
    let usageBits: Int
    private(set) var buffer: JSValue = .undefined
    private var capacity = 0

    init(usageBits: Int) {
        self.usageBits = usageBits
    }

    /// Returns true when a new GPU buffer object was created.
    @discardableResult
    mutating func ensureCapacity(_ bytes: Int, device: JSValue) -> Bool {
        guard bytes > capacity || buffer.isUndefined else { return false }
        var newCapacity = max(capacity, 4096)
        while newCapacity < bytes { newCapacity *= 2 }
        if !buffer.isUndefined {
            _ = buffer.destroy()
        }
        buffer = device.createBuffer([
            "size": JSValue.number(Double(newCapacity)),
            "usage": JSValue.number(Double(usageBits)),
        ].jsValue)
        capacity = newCapacity
        return true
    }
}

enum GPU {
    static let copyDst = 8
    static let index = 16
    static let vertex = 32
    static let uniform = 64
    static let renderAttachment = 16
    static let vertexStage = 1
    static let fragmentStage = 2
}
#endif
