// AppRuntime — the native mirror of `WebRuntime`: a programmatic AppKit app
// (no storyboard/xib) with an `NSWindow` hosting an `MTKView`, a per-frame tick
// loop driven off the MTKView delegate, and input forwarding through
// `MetalView`. It logs the timeline first (smoke parity with `WebRuntime`),
// binds the Metal renderer to the scene, and lets `Engine.tick` update + render
// each bound scene every frame.

import PhysicaFoundation
import PhysicaKernel

#if os(macOS)
import AppKit
import MetalKit
import QuartzCore

@MainActor
public final class AppRuntime: NSObject {
    public let engine: Engine
    let scene: Scene
    let renderer: MetalRenderer
    let view: MetalView
    let playbackBar: PlaybackBar
    let window: NSWindow

    private var clock = FrameClock()

    /// Builds the window/view/renderer and binds the scene. Returns nil if
    /// Metal is unavailable (the caller degrades gracefully).
    @discardableResult
    public static func run(
        engine: Engine, scene: Scene, size: CGSize = CGSize(width: 1280, height: 800)
    ) -> AppRuntime? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = try? MetalRenderer(device: device) else {
            print("Physica: Metal renderer unavailable")
            return nil
        }
        // Log the timeline first so a GPU-less run (or CI) still prints it, just
        // like WebRuntime does.
        print("Physica: scene ready\n" + scene.timeline.debugString)

        let runtime = AppRuntime(engine: engine, scene: scene, renderer: renderer, device: device, size: size)
        engine.bind(renderer, to: scene)
        print("Physica: scene size \(Double(scene.size.x)) × \(Double(scene.size.y))")
        print("Physica: Metal renderer running")
        return runtime
    }

    private init(
        engine: Engine, scene: Scene, renderer: MetalRenderer, device: MTLDevice, size: CGSize
    ) {
        self.engine = engine
        self.scene = scene
        self.renderer = renderer

        let view = MetalView(frame: CGRect(origin: .zero, size: size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.sampleCount = 4
        view.boundEngine = engine
        view.boundScene = scene
        view.translatesAutoresizingMaskIntoConstraints = false
        self.view = view

        let bar = PlaybackBar(scene: scene)
        self.playbackBar = bar

        // Container: the MetalView fills it; the playback HUD floats inset over
        // the bottom (added last, so it composites above the Metal layer).
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.addSubview(view)
        container.addSubview(bar)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            bar.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
            bar.heightAnchor.constraint(equalToConstant: 40),
        ])

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = scene.name.isEmpty ? "Physica" : scene.name
        window.contentView = container
        window.center()
        self.window = window

        super.init()

        view.delegate = self
        renderer.currentView = view
        configureApplicationMenu()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        clock.reset()
    }

    /// Minimal main menu: an app menu with Quit ⌘Q (no nib).
    private func configureApplicationMenu() {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        AppRoots.installQuitMenu(application)
        application.activate(ignoringOtherApps: true)
    }
}

extension AppRuntime: MTKViewDelegate {
    public nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    public nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let deltaTime = clock.tick()
            renderer.currentView = view
            engine.tick(deltaTime: deltaTime)
            playbackBar.sync()
        }
    }
}

/// Per-frame wall-clock delta with the standard gap clamp (first frame, tab
/// switch, breakpoint → one frame). Shared by the window (`AppRuntime`) and deck
/// (`DeckPane`) frame loops so the clamp lives in one place.
struct FrameClock {
    private var lastTime: CFTimeInterval = 0

    /// Reset the reference so the next `tick()` returns ~one frame, not a giant
    /// gap — call when a paused/hidden view becomes visible again.
    mutating func reset() { lastTime = CACurrentMediaTime() }

    mutating func tick() -> CFTimeInterval {
        let now = CACurrentMediaTime()
        var delta = now - lastTime
        lastTime = now
        if delta <= 0 || delta > 0.1 { delta = 1.0 / 60 }
        return delta
    }
}
#endif
