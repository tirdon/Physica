// Fetches a TTF over HTTP and parses it with the pure-Swift Font parser.
//
// This file is the **BridgeJS pilot**: the JS surface it touches is imported
// through the modern typed macros (`@JSFunction(from: .global)` fetch, a
// `@JSClass` Response wrapper with a `@JSGetter`) instead of dynamic
// `JSObject.global` lookups. The macros expand to `@_extern(wasm)` thunks the
// BridgeJS build plugin generates, so PhysicaWeb carries the plugin + the
// `Extern` experimental feature in Package.swift. Everything read from
// `globalThis` needs no `getImports()` entry. Promise awaits deliberately stay
// on `JSPromise.value()` (typed promise returns are still the macros' rough
// edge). The other web files stay on the dynamic style until this pattern has
// soaked.

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

// MARK: BridgeJS typed imports (the pilot surface)

/// `globalThis.fetch(url)` — returns the response promise.
@JSFunction(from: .global) func fetch(_ url: String) throws(JSException) -> JSObject

/// The awaited `Response`: the two members `load` reads, typed.
@JSClass struct FetchResponse {
    @JSGetter var ok: Bool
    @JSFunction func arrayBuffer() throws(JSException) -> JSObject
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
        let responseValue = try await JSPromise(unsafelyWrapping: fetch(url)).value()
        guard let responseObject = responseValue.object else {
            throw FontLoaderError.fetchFailed(url)
        }
        let response = FetchResponse(unsafelyWrapping: responseObject)
        guard try response.ok else {
            throw FontLoaderError.fetchFailed(url)
        }
        let buffer = try await JSPromise(unsafelyWrapping: response.arrayBuffer()).value()
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
