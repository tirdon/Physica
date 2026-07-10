// PhysicaApplication — the one-statement native entry point, the macOS mirror of
// the wasm `Storytelling` facade (`Sources/WASM/Facade/Storytelling`). It
// registers the CoreText default faces into `FontBook` (skipping any role the
// author pre-filled via `Config`), then hands the same scene declaration to one
// of two presentations:
//
//     PhysicaApplication(name: "pendulum") { scene in … }.run()                 // window
//     try PhysicaApplication(name: "pendulum") { scene in … }.write(to: url)    // file
//
// The init is a builder — it only captures the name + body (and fills fonts), so
// the same statement can open an interactive window (`run`) or render headlessly
// to an image/video (`write`). Config interplay is identical to the web facade:
// `Config.background`, `Config.camera`, and `Config.textColor` are picked up by
// every new `Scene` at init, so the facade only fills fonts and never clobbers
// them.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

#if os(macOS)
import AppKit

@MainActor
public struct PhysicaApplication {
    private let name: String
    private let body: @MainActor (Scene) -> Void

    /// Captures the scene declaration and registers the default CoreText faces
    /// (idempotent). The scene itself is built lazily by `run`/`write`.
    public init(name: String = "scene", _ body: @escaping @MainActor (Scene) -> Void) {
        PhysicaApplication.installDefaultFonts()
        self.name = name
        self.body = body
    }

    /// Presents the scene in a window (Metal renderer + playback HUD + pointer/
    /// keyboard input) and blocks in `NSApp.run()`. The interactive entry point.
    public func run() {
        let engine = Engine()
        let scene = engine.makeScene(name: name, body)
        guard let runtime = AppRuntime.run(engine: engine, scene: scene) else { return }
        AppRoots.keep(runtime)
        NSApplication.shared.run()
    }

    /// Renders the scene headlessly to `url` — no window. The file's `UTType`
    /// picks the medium: a still-image type (`.png`/`.jpeg`/`.tiff`/…) captures
    /// one frame at `time`; a movie type (`.mov`/`.mp4`) encodes `[0, duration]`
    /// at `fps` (duration defaults to the timeline length). Systems run live, so
    /// the pendulum has actually swung by the captured instant.
    public func write(
        to url: URL,
        size: CGSize = CGSize(width: 1280, height: 800),
        duration: TimeInterval? = nil,
        fps: Int = 60,
        time: TimeInterval = 0
    ) throws {
        let engine = Engine()
        let scene = engine.makeScene(name: name, body)
        defer { _ = engine }   // keep the scene's owner alive across the render
        try SceneExporter.write(
            scene: scene, to: url, size: size, duration: duration, fps: fps, time: time
        )
    }

    /// Registers the CoreText default faces into `FontBook`, skipping roles the
    /// author already filled — the native counterpart of the web facade's
    /// `loadDefaultFonts`. System font for body (→ `FontBook.fallback`, which
    /// also serves title/heading/caption), an italic serif for math, Menlo for
    /// mono. Public so a headless driver can register fonts without a window.
    public static func installDefaultFonts() {
        if FontBook.fallback == nil {
            FontBook.fallback = CoreTextFont.bake(CoreTextFont.systemFont())
        }
        // Roles whose preferred face is absent reuse the already-baked system
        // face rather than re-baking the full charset per role.
        let system = FontBook.fallback
        func fill(_ role: FontRole, named name: String) {
            guard !FontBook.hasRegistration(for: role) else { return }
            let face = CoreTextFont.namedFont(name).map(CoreTextFont.bake) ?? system
            if let face { FontBook.register(face, for: role) }
        }
        fill(.math, named: "Times-Italic")
        fill(.mono, named: "Menlo-Regular")
    }
}

/// Keeps the runtime (window/view/renderer) alive for the app's lifetime — the
/// native `FacadeRoots`. The `PhysicaApplication` statement is fire-and-forget.
@MainActor
enum AppRoots {
    private static var kept: [AnyObject] = []
    static func keep(_ object: AnyObject) { kept.append(object) }

    /// Installs the minimal main menu (an app menu with Quit ⌘Q, no nib) shared
    /// by the window (`AppRuntime`) and document (`PhysicaDocument`) facades.
    static func installQuitMenu(_ application: NSApplication = .shared) {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        application.mainMenu = mainMenu
    }
}
#endif
