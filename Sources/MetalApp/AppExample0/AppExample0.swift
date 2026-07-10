// AppExample0 — the native macOS pendulum demo, the sibling of the wasm
// Example1. One `PhysicaApplication` declaration, presented one of two ways —
// swap the active statement below:
//
//   app.run()                 // open the interactive window (Metal + playback HUD)
//   try app.write(to: url)    // render headlessly to a file (image or video,
//                             //   chosen from the URL's UTType)

#if os(macOS)
import PhysicaApp

@main
struct AppExample0 {
    @MainActor
    static func main() throws {
        let app = PhysicaApplication(name: "pendulum") { scene in
            PendulumDemo.build(scene, font: FontBook.resolve(.body).font, formula: nil)
        }

        app.run()

        // Headless export instead of a window (the UTType picks image vs video):
        //   try app.write(to: URL(fileURLWithPath: "pendulum.png"), time: 5)
        //   try app.write(to: URL(fileURLWithPath: "pendulum.mov"), duration: 6, fps: 60)
    }
}

#else

@main
struct AppExample0 {
    static func main() {
        print("AppExample0 is the native macOS pendulum demo — build and run it on macOS:")
        print("  swift run AppExample0   # windowed app; edit main() to app.write(to:) for a file")
    }
}

#endif
