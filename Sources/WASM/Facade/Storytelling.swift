// Storytelling — the one-statement browser entry point. Two spellings:
//
//   Storytelling {                       // story mode (slides)
//       Slide("Intro", onDisappear: .fadeOut) { scene in … }
//       Slide { scene in … }
//   }
//
//   Storytelling { scene in … }          // animation mode (one scene)
//
// The initializer captures the authoring closures UNEXECUTED and schedules the
// mount; `mount` then loads the default faces (→ `FontBook`, so `Text(...)`
// inside the closures resolves), builds the Engine/Scene/Story, injects the
// page chrome (`WebpageShell`), and hands off to `StoryRuntime`/`WebRuntime`.
// Everything the mount produces is parked in `FacadeRoots` — the author's
// statement is fire-and-forget. The demo's `main` still installs the
// JavaScriptEventLoop executor and wraps this in a `Task`, exactly like the
// pre-facade entry points.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
public struct Storytelling {
    /// Story mode: a builder of `Slide(...)` elements over one scrubbable
    /// timeline, presented by the scrollytelling shell.
    @discardableResult
    public init(
        name: String = "story",
        options: StoryOptions = StoryOptions(),
        @StoryBuilder _ slides: @escaping @MainActor () -> [SlideSpec]
    ) {
        Task { @MainActor in
            await Storytelling.mount(name: name, options: options, slides: slides)
        }
    }

    /// Animation mode: a single scene script, presented with playback controls.
    @discardableResult
    public init(
        name: String = "scene",
        _ body: @escaping @MainActor (Scene) -> Void
    ) {
        Task { @MainActor in
            await Storytelling.mount(name: name, body: body)
        }
    }

    /// Story mode, script form: full access to the `Story` (captions, actions,
    /// carry/clear) for rich scrollytelling scripts — the labeled-closure
    /// counterpart of the `Slide(...)` builder:
    /// `Storytelling(story: { story in WaveStory.build(story) })`.
    @discardableResult
    public init(
        name: String = "story",
        options: StoryOptions = StoryOptions(),
        story configure: @escaping @MainActor (Story) -> Void
    ) {
        Task { @MainActor in
            await Storytelling.mount(name: name, options: options, configure: configure)
        }
    }

    // MARK: Mounts

    private static func mount(
        name: String, options: StoryOptions, slides: @MainActor () -> [SlideSpec]
    ) async {
        await mount(name: name, options: options) { story in
            for spec in slides() {
                story.slide(spec)
            }
        }
    }

    private static func mount(
        name: String, options: StoryOptions, configure: @MainActor (Story) -> Void
    ) async {
        await loadDefaultFonts()
        let engine = Engine()
        let scene = engine.makeScene(name: name) { _ in }
        let story = Story(scene: scene, options: options)
        configure(story)
        WebpageShell.injectStoryShell()
        let runtime = await StoryRuntime.run(engine: engine, story: story)
        FacadeRoots.keep(runtime)
    }

    private static func mount(name: String, body: @MainActor (Scene) -> Void) async {
        await loadDefaultFonts()
        let engine = Engine()
        let scene = engine.makeScene(name: name, body)
        WebpageShell.injectSceneShell()
        let runtime = await WebRuntime.run(engine: engine, scene: scene)
        FacadeRoots.keep(runtime)
    }

    /// Fetches the default faces concurrently and fills `FontBook`. Failures
    /// degrade (`Text()` renders empty glyphs) rather than blocking the mount —
    /// the GPU-free smoke path has no usable fetch, and the story must still
    /// log and boot.
    static func loadDefaultFonts() async {
        async let bodyFace: Font? = try? FontLoader.load()
        async let mathFace: Font? = try? FontLoader.loadComputerModern()
        async let monoFace: Font? = try? FontLoader.loadMono()

        if let font = await bodyFace {
            FontBook.fallback = font
        } else {
            _ = JSObject.global.console.warn(
                "Physica: default font unavailable — Text() degrades to empty glyphs"
            )
        }
        if let font = await mathFace { FontBook.register(font, for: .math) }
        if let font = await monoFace { FontBook.register(font, for: .mono) }
    }
}

#endif
