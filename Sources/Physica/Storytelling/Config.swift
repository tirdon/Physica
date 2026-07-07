// Config — the author-facing defaults singleton. Set values once at the top of
// a demo's `main` (before the `Storytelling`/`Document` statement); scenes and
// `Text(...)` entities created afterwards pick them up. Fonts route through
// `FontBook` (Config is the authoring surface, FontBook stays the resolver);
// the web facade's default-font fetch skips any face the author supplied here.
//
//   let face = try await Font.load("https://…/face.ttf")   // web, async
//   Config.defaultFont(face)
//   Config.background = .blackboard
//   Storytelling { scene in … }

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public enum Config {
    // MARK: Fonts

    /// Installs `font` as the default face: every role without its own
    /// registration resolves to it (`FontBook.fallback`), and it becomes
    /// `Font.default` — what a bare `TextEntity("Hi")` renders with.
    public static func defaultFont(_ font: Font) {
        FontBook.fallback = font
    }

    /// Registers `font` for one role; `size` overrides the role's built-in
    /// scale (`Text("…", font: role)` resolves both).
    public static func font(_ font: Font, for role: FontRole, size: Real? = nil) {
        FontBook.register(font, for: role, size: size)
    }

    // MARK: Scene defaults

    /// Background newly created scenes start with (`scene.background` /
    /// `story.background` still override per scene).
    public static var background: SceneBackground = .color(.background)

    /// Camera projection newly created scenes start with.
    public static var camera: Camera.Projection = .orthographicFit(extent: 10)

    /// Color `Text(...)` uses when no `color:` is passed.
    public static var textColor: Color = .white

    // MARK: Web runtime state

    /// Whether MathJax finished loading — the facade attempts the load at
    /// mount and sets this, so authoring closures can branch
    /// (`Config.mathJaxReady ? MathJaxTokenProvider() : …`). Always false on
    /// the host and in GPU-free smoke runs (no DOM).
    public static var mathJaxReady = false

    /// Restores every default and clears the font registrations (tests; a
    /// fresh editor session).
    public static func reset() {
        background = .color(.background)
        camera = .orthographicFit(extent: 10)
        textColor = .white
        mathJaxReady = false
        FontBook.reset()
    }
}
