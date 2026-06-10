// Engine — owns scenes, their render-backend bindings, and shared input state.
// The platform layer (wasm executable) drives `tick` from requestAnimationFrame,
// feeds visibility from IntersectionObserver, and toggles the Shift debug overlay.

@MainActor
public final class Engine {
    public private(set) var scenes: [Scene] = []

    /// Shift held → snapshots include entity/group index labels.
    public var isDebugOverlayActive = false

    private struct Binding {
        let scene: Scene
        let backend: any RenderBackend
    }

    private var bindings: [Binding] = []

    public init() {}

    /// Creates a scene and runs its script synchronously (Manim style: the script
    /// enqueues timeline clips; playback happens over subsequent ticks).
    @discardableResult
    public func makeScene(name: String = "", _ script: (Scene) -> Void) -> Scene {
        let scene = Scene()
        scene.name = name
        scenes.append(scene)
        script(scene)
        return scene
    }

    public func bind(_ backend: any RenderBackend, to scene: Scene) {
        bindings.removeAll { $0.scene === scene }
        bindings.append(Binding(scene: scene, backend: backend))
        scene.viewportAspect = backend.aspectRatio
    }

    /// IntersectionObserver hook — invisible scenes skip update and render.
    public func setVisibility(_ visible: Bool, forSceneID id: UInt64) {
        scenes.first(where: { $0.id == id })?.isVisible = visible
    }

    /// One frame: update + render every visible bound scene.
    public func tick(deltaTime: TimeInterval) {
        for binding in bindings where binding.scene.isVisible {
            binding.scene.viewportAspect = binding.backend.aspectRatio
            binding.scene.update(deltaTime: deltaTime)
            binding.backend.render(
                binding.scene.snapshot(includeDebugLabels: isDebugOverlayActive)
            )
        }
    }
}
