// StoryStudio — a standalone, in-browser WYSIWYG storytelling-authoring app for
// Physica, compiled to its own wasm bundle. It is the editor counterpart of the
// Example0 *story*: instead of a hand-authored `Story`, the slides come from a
// serializable `StoryDocument` that the user edits, which a `StoryCompiler`
// lowers into a fresh, scrubbable `Story` on every change (the timeline is
// append-only, so editing = rebuild, never mutate-in-place).
//
// This file is the thin WASI entry point: load the font, build the starter
// document, compile it, and hand the result to `StoryRuntime` (the same browser
// shell Example0 uses). The Document / Compiler / History layers live in plain
// (platform-neutral) files so `swift build` type-checks them on the host and the
// unit tests exercise them with no GPU or DOM.
//
// Build its bundle (separate output dir so it doesn't clobber the demo's js/):
//   swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads \
//     --allow-writing-to-directory js-studio js --use-cdn \
//     --output js-studio --product StoryStudio
// then serve with `bun bunserver.js` and open /studio.html.

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop
import Physica

@main
struct StoryStudio {
    // Retained for the lifetime of the page so the rAF loop / DOM listeners stay live.
    @MainActor static var app: StudioApp?

    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        Task { @MainActor in
            await boot()
        }
    }

    @MainActor
    static func boot() async {
        let console = JSObject.global.console

        let font: Font?
        do {
            font = try await FontLoader.load()
        } catch {
            font = nil
            _ = console.warn("StoryStudio: font unavailable —", String(describing: error))
        }

        app = await StudioApp.boot(font: font)
    }
}

#else

@main
struct StoryStudio {
    static func main() {
        print("StoryStudio is a wasm app; build with:")
        print("swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-studio js --use-cdn --output js-studio --product StoryStudio")
    }
}

#endif
