// ArticleStoryDeck — a `presentation {}` block rendered as a *real* Physica Story:
// an embedded WebGPU canvas driving one scrubbable timeline partitioned into
// slides, exactly like the standalone story demos (Example0 / Example2), but
// hosted inline in the article rather than owning the page.
//
// Why not `StoryRuntime`? That shell owns the whole page — window scroll ↔ scrub,
// body-level spacers, `window.scrollTo`. An article needs its own page scroll for
// reading, and several decks can't each own it. So this reuses the *engine*
// (Engine / Scene / Story / StoryPlayer / WebGPURenderer / RAFDriver) but with a
// local controller: the slide title `.write`s onto the dark stage, the body prose
// narrates in a caption band below it (typeset by the shell's MathJax), and Back /
// Next / dots + Left/Right arrows (while hovered) drive `StoryPlayer` beats.
//
// Degrades: no font → titles drop but captions still narrate; no WebGPU → the
// canvas stays blank but the caption band and nav still work off the player.

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
public final class ArticleStoryDeck {
    // Palette for the dark embedded stage.
    static let chalk = Color(hex: 0xF2F2EC)
    static let accent = Color(hex: 0x4CC878)

    private let engine: Engine
    private let story: Story
    private let player: StoryPlayer
    private let pending: PendingDeck
    private let dom: JSObject

    private var renderer: WebGPURenderer?
    private var driver: RAFDriver?
    private var visibilityObserver: VisibilityObserver?
    private var closures: [JSClosure] = []

    /// Guards `revealFirstSlideIfNeeded()` — the observer can report "visible"
    /// more than once (e.g. scroll back into view), but slide 0 is only built once.
    private var hasRevealed = false

    private var hovered = false
    private var lastCaption = "\u{0}"   // sentinel so the first real caption always renders
    private var lastIndex = -1

    private init(engine: Engine, story: Story, player: StoryPlayer, pending: PendingDeck, dom: JSObject) {
        self.engine = engine
        self.story = story
        self.player = player
        self.pending = pending
        self.dom = dom
    }

    /// Builds the story from the deck's slides, boots a WebGPU renderer on the
    /// (already-mounted) canvas, and starts the rAF loop. Returns `nil` only when
    /// there is no DOM.
    static func boot(_ pending: PendingDeck, font: Font?) async -> ArticleStoryDeck? {
        guard let dom = JSObject.global.document.object else { return nil }

        let engine = Engine()
        let scene = engine.makeScene(name: "article-story") { _ in }
        let story = Story(scene: scene)
        story.background = .blackboard

        // One slide per deck slide: the body prose (if any) always narrates as
        // the caption. The visual content is either the author's own `animate`
        // closure (full control of the live `Scene`) or, absent that, the
        // default title + accent-underline treatment.
        for slide in pending.slides {
            story.slide(slide.title) { s in
                story.caption(captionText(slide))
                if let animate = slide.animate {
                    animate(s)
                    return
                }
                if let font {
                    let heading = TextEntity(slide.title, font: font, fontSize: 0.72, color: chalk)
                    heading.position = Position(0, 0.55, 0)
                    s.play(.write(heading), for: 0.9.s)
                }
                let underline = Line(
                    start: Position(-2.4, -0.35, 0), end: Position(2.4, -0.35, 0),
                    width: 0.05, color: accent
                )
                s.play(.draw(underline), for: 0.6.s)
            }
        }

        let player = StoryPlayer(story: story)
        let deck = ArticleStoryDeck(engine: engine, story: story, player: player, pending: pending, dom: dom)
        deck.wireControls()

        do {
            let renderer = try await WebGPURenderer.create(canvasID: pending.canvasID)
            engine.bind(renderer, to: scene)
            deck.renderer = renderer
            // A long article can carry the deck's canvas far off-screen; stop
            // ticking it while it's scrolled out of view, same as WebRuntime. The
            // same signal also drives the deferred first reveal below.
            let canvas = dom.getElementById!(pending.canvasID)
            deck.visibilityObserver = VisibilityObserver(
                engine: engine, canvas: canvas, sceneID: scene.id,
                onChange: { [weak deck] visible in
                    guard visible else { return }
                    deck?.revealFirstSlideIfNeeded()
                }
            )
        } catch {
            _ = JSObject.global.console.warn(
                "ArticleStoryDeck: WebGPU unavailable —", String(describing: error))
        }

        let driver = RAFDriver()
        driver.start { [weak deck] deltaTime in deck?.frame(deltaTime: deltaTime) }
        deck.driver = driver

        // Counter/caption already read correctly at t=0 (slide 0's own rest
        // state) — the content itself (shapes/title+underline) is built the
        // first time the deck actually scrolls into view, not here at boot,
        // so a reader never finds it already finished before they've reached it.
        deck.syncCaption()
        deck.syncCounter()
        return deck
    }

    /// Builds slide 0 — just shy of its end boundary so the slide index (and the
    /// counter) stays 0 rather than rolling into slide 1 — the first time the
    /// deck is observed intersecting the viewport. One-shot: later visibility
    /// changes (scrolling away and back) don't re-trigger it.
    private func revealFirstSlideIfNeeded() {
        guard !hasRevealed else { return }
        hasRevealed = true
        player.scrub(slide: 0, progress: 0.995)
    }

    private func frame(deltaTime: TimeInterval) {
        player.tick(deltaTime: deltaTime)   // advances an in-flight arrow tween
        engine.tick(deltaTime: deltaTime)   // renders the bound scene (no-op if unbound)
        syncCaption()
        syncCounter()
    }

    // MARK: Controls

    private func wireControls() {
        onClick(pending.prevID) { [weak self] in self?.player.previousStep() }
        onClick(pending.nextID) { [weak self] in self?.player.nextStep() }
        for (index, dotID) in pending.dotIDs.enumerated() {
            onClick(dotID) { [weak self] in self?.player.scrub(slide: index, progress: 0.995) }
        }

        // Hover flag: Left/Right step the story only while the pointer is over this
        // deck, so several decks never fight and page scroll (Up/Down) is untouched.
        onStage("pointerenter") { [weak self] _ in self?.hovered = true }
        onStage("pointerleave") { [weak self] _ in self?.hovered = false }

        let keydown = JSClosure { [weak self] arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated { self?.handleKey(event) }
            return .undefined
        }
        closures.append(keydown)
        _ = JSObject.global.jsValue.addEventListener("keydown", keydown)
    }

    private func handleKey(_ event: JSValue) {
        guard hovered else { return }
        switch event.key.string ?? "" {
        case "ArrowRight": _ = event.preventDefault(); player.nextStep()
        case "ArrowLeft": _ = event.preventDefault(); player.previousStep()
        default: break
        }
    }

    private func onClick(_ id: String, _ handler: @escaping @MainActor () -> Void) {
        let element = dom.getElementById!(id)
        guard element.object != nil else { return }
        let closure = JSClosure { _ in
            MainActor.assumeIsolated { handler() }
            return .undefined
        }
        closures.append(closure)
        _ = element.addEventListener("click", closure)
    }

    private func onStage(_ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
        let element = dom.getElementById!(pending.stageID)
        guard element.object != nil else { return }
        let closure = JSClosure { arguments in
            let e = arguments.first ?? .undefined
            MainActor.assumeIsolated { handler(e) }
            return .undefined
        }
        closures.append(closure)
        _ = element.addEventListener(event, closure)
    }

    // MARK: Sync (caption band + slide counter/dots)

    private func syncCaption() {
        let text = player.currentCaption
        guard text != lastCaption else { return }
        lastCaption = text
        let element = dom.getElementById!(pending.captionID)
        guard element.object != nil else { return }
        element.innerHTML = .string("")
        if text.isEmpty {
            element.className = .string("story-deck-caption")
            return
        }
        ArticleInline.append(text, to: element, using: dom)
        element.className = .string("story-deck-caption show")
        typeset(element)
    }

    private func syncCounter() {
        let index = player.currentSlideIndex
        guard index != lastIndex else { return }
        lastIndex = index
        let count = dom.getElementById!(pending.countID)
        if count.object != nil {
            count.textContent = .string("\(index + 1) / \(story.slides.count)")
        }
        for (i, dotID) in pending.dotIDs.enumerated() {
            let dot = dom.getElementById!(dotID)
            guard dot.object != nil else { continue }
            dot.className = .string(i == index ? "deck-dot active" : "deck-dot")
        }
    }

    /// Typesets one element with the shell's global MathJax (tex-mml-chtml). No-op
    /// until MathJax has loaded; the next caption change re-typesets.
    private func typeset(_ element: JSValue) {
        guard let mathJax = JSObject.global.MathJax.object,
              mathJax.typesetPromise.function != nil else { return }
        let array = JSObject.global.Array.function!.new()
        _ = array.push!(element)
        _ = mathJax.typesetPromise!(array)
    }

    /// The plain narration text for a slide: its paragraphs (and any inline-math
    /// blocks re-delimited for MathJax), joined for the caption band.
    static func captionText(_ slide: DeckSlide) -> String {
        var parts: [String] = []
        for block in slide.blocks {
            switch block {
            case let .paragraph(text): parts.append(text)
            case .headline(let text), .subheadline(let text): parts.append(text)
            case let .math(_, _, tex): parts.append("\\(" + tex + "\\)")
            default: break
            }
        }
        return parts.joined(separator: " ")
    }
}
#endif
