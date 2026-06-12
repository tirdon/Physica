// Fetches a TTF over HTTP and parses it with the pure-Swift Font parser.

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
