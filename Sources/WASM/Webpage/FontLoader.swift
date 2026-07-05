// Fetches a TTF over HTTP and parses it with the pure-Swift Font parser.

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

enum FontLoaderError: Error {
    case fetchFailed(String)
}

@MainActor
public enum FontLoader {
    /// Default demo face — a glyf-based TrueType file on a versioned CDN.
    public static let defaultURL =
        "https://cdn.jsdelivr.net/npm/@expo-google-fonts/roboto@0.2.3/Roboto_400Regular.ttf"

    /// Computer Modern Unicode Serif (`cmunrm`) — LaTeX's body face, as a glyf
    /// TrueType the pure-Swift `Font` parser handles. Pinned to a commit so the
    /// bytes are reproducible under COEP. Pairs with the dvisvgm math path so
    /// host-baked formulas and runtime text share the same face.
    public static let computerModernURL =
        "https://cdn.jsdelivr.net/gh/dreampulse/computer-modern-web-font@e9977be1283466992a2dede47a342655d8426fee/font/Serif/cmunrm.ttf"

    /// Computer Modern Unicode Typewriter (`cmuntt`) — the monospace face for
    /// code listings. Same family as ``computerModernURL``, fixed-width glyphs.
    public static let monoURL =
        "https://cdn.jsdelivr.net/gh/dreampulse/computer-modern-web-font@e9977be1283466992a2dede47a342655d8426fee/font/Typewriter/cmuntt.ttf"

    /// Computer Modern Serif — `load(url: computerModernURL)`.
    public static func loadComputerModern() async throws -> Font {
        try await load(url: computerModernURL)
    }

    /// Computer Modern Typewriter (monospace, for code) — `load(url: monoURL)`.
    public static func loadMono() async throws -> Font {
        try await load(url: monoURL)
    }

    public static func load(url: String = defaultURL) async throws -> Font {
        let global = JSObject.global
        let response = try await JSPromise(unsafelyWrapping: global.fetch!(url).object!).value()
        guard response.ok.boolean == true else {
            throw FontLoaderError.fetchFailed(url)
        }
        let buffer = try await JSPromise(unsafelyWrapping: response.arrayBuffer().object!).value()
        let typed = JSTypedArray<UInt8>(
            unsafelyWrapping: JSObject.global.Uint8Array.function!.new(buffer)
        )
        var bytes = [UInt8](repeating: 0, count: typed.length)
        bytes.withUnsafeMutableBufferPointer { destination in
            typed.copyMemory(to: destination)
        }
        return try Font(data: bytes)
    }
}
#endif
