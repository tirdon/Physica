// GPU helpers — renderer-support types split from WebGPURenderer.swift:
// RendererError, GrowableBuffer (a resize-on-demand GPUBuffer), and GPU (WebGPU
// usage/stage bit constants).

import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel
import PhysicaPlotting
import PhysicaStory
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

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
