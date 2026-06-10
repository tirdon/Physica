// PhysicsEngine — wasm browser entry point for the Physica framework.
// The framework lives in Sources/Physica; this target is the visual test host
// for index.html (renderer, DOM glue, demo scenes).

#if os(WASI)
import JavaScriptKit
import JavaScriptEventLoop

@main
struct PhysicsEngineApp {
    static func main() {
        JavaScriptEventLoop.installGlobalExecutor()
        Task { @MainActor in
            await App.boot()
        }
    }
}

#else

@main
struct PhysicsEngineApp {
    static func main() {
        print("PhysicsEngine is the wasm entry point; build with:")
        print("swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads --allow-writing-to-directory js js --use-cdn --output js")
    }
}

#endif
