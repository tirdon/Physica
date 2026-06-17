// App — load resources, build a demo scene, hand it to the framework shell.
// `index.html` gets the pendulum (animation mode); `story.html` sets
// `globalThis.physicaStory` before init and gets the scrollytelling equation
// game (story mode). The Bun smoke has no DOM and no flag → pendulum path,
// byte-identical to before.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum App {
    static var runtime: WebRuntime?
    static var storyRuntime: StoryRuntime?
    static var storyGame: EquationGame?

    static func boot() async {
        let console = JSObject.global.console
        let isStory = JSObject.global.physicaStory.boolean ?? false

        let font: Font?
        do {
            font = try await FontLoader.load()
        } catch {
            font = nil
            _ = console.warn("Physica: font unavailable —", String(describing: error))
        }

        if isStory {
            await bootStory(font: font)
        } else {
            await bootPendulum(font: font)
        }
    }

    // MARK: Animation mode (index.html, Bun smoke)

    private static func bootPendulum(font: Font?) async {
        let console = JSObject.global.console
        var formula: TextEntity?
        do {
            formula = try await MathJaxLoader.formula(
                "\\ddot{\\theta} = -\\frac{g}{\\ell}\\,\\sin\\theta", fontSize: 0.75
            )
        } catch {
            _ = console.warn("Physica: MathJax unavailable —", String(describing: error))
        }

        let engine = Engine()
        let scene = engine.makeScene(name: "pendulum") { scene in
            PendulumDemo.build(scene, font: font, formula: formula)
        }
        runtime = await WebRuntime.run(engine: engine, scene: scene)
    }

    // MARK: Story mode (story.html)

    private static func bootStory(font: Font?) async {
        let console = JSObject.global.console

        // Equation tokens render with MathJax when available, otherwise a font,
        // otherwise stub boxes — the story still works, just less pretty.
        let provider: TokenGlyphProvider
        do {
            try await MathJaxLoader.load()
            provider = MathJaxTokenProvider()
        } catch {
            _ = console.warn("Physica: MathJax unavailable —", String(describing: error))
            provider = font.map { FontTokenGlyphProvider(font: $0) } ?? StubTokenGlyphProvider()
        }

        let engine = Engine()
        let scene = engine.makeScene(name: "equation-story") { _ in }
        let story = Story(scene: scene)
        storyGame = EquationStoryDemo.build(story, font: font, provider: provider)
        storyRuntime = await StoryRuntime.run(engine: engine, story: story)
    }
}
#endif
