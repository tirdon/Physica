// StoryRuntime — the story-mode browser shell (the scrollytelling counterpart of
// WebRuntime). The canvas is pinned; page scroll scrubs the current slide's
// timeline segment; Up/Down change slides, Left/Right change steps; DOM buttons
// trigger parallel actions. One writer to the playhead (StoryPlayer): scroll
// maps to scrub, arrows run tweens that mirror the scrollbar back. Like
// WebRuntime it logs the story first (GPU-free smoke relies on that) and treats
// a missing renderer as non-fatal.
//
// Mobile: a horizontal touch swipe over the canvas drives step navigation
// (swipe left → next step, right → previous), via the core `SwipeRecognizer`.
// Horizontal only — the canvas keeps `touch-action: pan-y`, so the browser
// consumes vertical drags as page scroll (the existing scroll-scrub) and a
// vertical swipe fires `pointercancel`, which simply aborts the recognizer.
// Swipes are skipped over a draggable token and while an arrow tween runs.

#if os(WASI)
import JavaScriptKit

@MainActor
public final class StoryRuntime {
    public private(set) var engine: Engine
    public private(set) var player: StoryPlayer
    private var story: Story
    /// The live scene currently bound to the renderer (swapped by `reload`).
    /// Exposed so an editor host can hit-test / project against it.
    public private(set) var scene: Scene

    /// When false, Shift / Option+Shift no longer drive the index overlays. Editor
    /// hosts (Story Studio) repurpose Shift for multi-select and turn this off so
    /// the debug labels don't flash over the stage. Forwarded to `InputBindings`,
    /// which owns the other Shift key listener.
    public var syncsDebugOverlay = true {
        didSet { inputBindings?.syncsDebugOverlay = syncsDebugOverlay }
    }

    private(set) var renderer: WebGPURenderer?
    private var rafDriver: RAFDriver?
    private var inputBindings: InputBindings?
    private var visibilityObserver: VisibilityObserver?
    private var overlay: DebugOverlay?
    private var closures: [JSClosure] = []

    private var hud: JSValue = .undefined
    private var caption: JSValue = .undefined
    private var lastCaption = ""
    private var canvas: JSValue = .undefined

    // Scroll ↔ time mapping: spacer heights sum to the scrollable range.
    private var spacerTops: [Double] = []
    private var spacerHeights: [Double] = []
    private var totalPixels: Double = 0

    /// DOM host ids, stored so `reload` can rebuild the spacers/actions in place.
    private var trackID = "story-track"
    private var actionsID = "story-actions"

    /// Horizontal-swipe recognizer for touch step navigation, and whether the
    /// in-flight touch gesture is being tracked as a candidate swipe.
    private var swipe = SwipeRecognizer()
    private var swipeTracking = false

    private var pendingScrollY: Double?
    /// The last scrollY we wrote via `mirrorScrollFromPlayer`, used to drop the
    /// browser's echo `scroll` event so it doesn't re-seek the playhead off the
    /// boundary an arrow tween just landed on.
    private var lastMirroredScrollY: Double?
    private var lastSlide = -1

    private init(engine: Engine, story: Story) {
        self.engine = engine
        self.story = story
        self.scene = story.scene
        self.player = StoryPlayer(story: story)
    }

    @discardableResult
    public static func run(
        engine: Engine,
        story: Story,
        canvasID: String = "main",
        overlayHostID: String = "scene-host",
        trackID: String = "story-track",
        actionsID: String = "story-actions",
        hudID: String = "story-hud",
        captionID: String = "story-caption"
    ) async -> StoryRuntime {
        let console = JSObject.global.console
        _ = console.log("Physica story:\n" + story.debugString)

        let runtime = StoryRuntime(engine: engine, story: story)
        let document = JSObject.global.document
        guard document.object != nil else {
            _ = console.warn("Physica: no DOM — story shell not started")
            return runtime
        }

        runtime.trackID = trackID
        runtime.actionsID = actionsID
        runtime.buildSpacers(trackID: trackID)
        runtime.buildActions(actionsID: actionsID)
        runtime.hud = document.getElementById(hudID)
        runtime.caption = document.getElementById(captionID)
        runtime.canvas = document.getElementById(canvasID)
        runtime.installScrollAndKeys()

        do {
            let renderer = try await WebGPURenderer.create(canvasID: canvasID)
            engine.bind(renderer, to: runtime.scene)
            _ = console.log("Physica: scene size", Double(runtime.scene.size.x), "×", Double(runtime.scene.size.y))

            runtime.inputBindings = InputBindings(engine: engine, scene: runtime.scene, canvas: runtime.canvas)
            runtime.installTouchGestures()
            runtime.visibilityObserver = VisibilityObserver(engine: engine, canvas: runtime.canvas, sceneID: runtime.scene.id)
            runtime.overlay = DebugOverlay(engine: engine, scene: runtime.scene, hostID: overlayHostID, canvas: runtime.canvas)
            runtime.renderer = renderer

            let driver = RAFDriver()
            driver.start { [weak runtime] deltaTime in
                runtime?.frame(deltaTime: deltaTime)
            }
            runtime.rafDriver = driver
            _ = console.log("Physica: story runtime running")
        } catch {
            _ = console.error("Physica: renderer unavailable —", String(describing: error))
        }
        runtime.syncHUD()
        return runtime
    }

    /// Swaps in a freshly compiled story without tearing down the renderer, rAF
    /// loop, or input/overlay listeners. The editor recompiles on every edit, so
    /// rebuilding the page each time would leak rAF loops and DOM listeners;
    /// instead we rebind the live renderer to the new scene (a fresh engine per
    /// compile means a single clean binding) and rebuild only the spacers/actions.
    public func reload(engine: Engine, story: Story) {
        self.engine = engine
        self.story = story
        self.scene = story.scene
        self.player = StoryPlayer(story: story)

        clearChildren(of: trackID)
        clearChildren(of: actionsID)
        spacerTops.removeAll()
        spacerHeights.removeAll()
        totalPixels = 0
        buildSpacers(trackID: trackID)
        buildActions(actionsID: actionsID)

        if let renderer {
            engine.bind(renderer, to: scene)
        }

        pendingScrollY = nil
        lastMirroredScrollY = nil
        lastSlide = -1
        lastCaption = ""
        syncHUD()
    }

    private func clearChildren(of id: String) {
        guard let document = JSObject.global.document.object else { return }
        var node = document.getElementById!(id)
        guard node.object != nil else { return }
        node.innerHTML = .string("")
    }

    // MARK: Per-frame

    private func frame(deltaTime: TimeInterval) {
        // Always tick: it advances an in-flight tween *and* the autoplay dwell (a
        // no-op when neither is active). An autoplay dwell can start a tween here.
        let wasTweening = player.isTweening
        player.tick(deltaTime: deltaTime)
        if player.isTweening {
            mirrorScrollFromPlayer()
            pendingScrollY = nil  // ignore scroll echoes while a tween drives the playhead
        } else if wasTweening {
            pendingScrollY = nil  // swallow the echo on the frame a tween lands
        } else if let target = pendingScrollY {
            pendingScrollY = nil
            scrub(toScrollY: target)
        }
        engine.tick(deltaTime: deltaTime)  // renders + advances interactions/drag/layout
        overlay?.sync()
        syncCaption()
        if player.currentSlideIndex != lastSlide {
            lastSlide = player.currentSlideIndex
            syncHUD()
        }
    }

    // MARK: Scroll mapping

    private func scrub(toScrollY scrollY: Double) {
        guard totalPixels > 0 else { return }
        let clamped = Swift.min(Swift.max(scrollY, 0), totalPixels)
        for index in story.slides.indices {
            let top = spacerTops[index]
            let height = Swift.max(spacerHeights[index], 1)
            if clamped < top + height || index == story.slides.count - 1 {
                player.scrub(slide: index, progress: Real((clamped - top) / height))
                return
            }
        }
    }

    private func mirrorScrollFromPlayer() {
        let state = player.state
        guard story.slides.indices.contains(state.slideIndex) else { return }
        let top = spacerTops[state.slideIndex]
        let height = spacerHeights[state.slideIndex]
        let target = top + Double(state.slideProgress) * height
        lastMirroredScrollY = target
        _ = JSObject.global.scrollTo!(0, target)
    }

    // MARK: DOM construction

    private func buildSpacers(trackID: String) {
        guard let document = JSObject.global.document.object else { return }
        var track = document.getElementById!(trackID)
        guard track.object != nil else { return }
        var cursor: Double = 0
        for slide in story.slides {
            let pixels = Double(story.slideScrollPixels(slide))
            spacerTops.append(cursor)
            spacerHeights.append(pixels)
            cursor += pixels
            var spacer = document.createElement!("div")
            spacer.className = .string("story-spacer")
            _ = spacer.setAttribute("style", "height: \(pixels)px; scroll-snap-align: start;")
            _ = spacer.setAttribute("data-slide", "\(slide.index)")
            _ = track.appendChild(spacer)
        }
        totalPixels = cursor
    }

    private func buildActions(actionsID: String) {
        guard let document = JSObject.global.document.object else { return }
        var host = document.getElementById!(actionsID)
        guard host.object != nil else { return }
        for action in story.actionList {
            var button = document.createElement!("button")
            button.textContent = .string(action.label)
            button.className = .string("story-action")
            let id = action.id
            let closure = JSClosure { [weak self] _ in
                MainActor.assumeIsolated { self?.player.trigger(actionID: id) }
                return .undefined
            }
            closures.append(closure)
            _ = button.addEventListener("click", closure)
            _ = host.appendChild(button)
        }
    }

    private func installScrollAndKeys() {
        let window = JSObject.global.jsValue
        let scroll = JSClosure { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let y = JSObject.global.scrollY.number ?? 0
                // Drop the echo `scroll` that our own mirrorScrollFromPlayer()
                // just caused. The browser quantizes scrollTo to device pixels, so
                // letting the echo through re-seeks the playhead a sub-pixel shy of
                // the boundary an arrow tween just landed on; nextStep/previousStep
                // then treat that boundary as still-ahead and the next Right/Left
                // arrow re-targets it instead of advancing. Real user scrolls move
                // far more than this threshold.
                if let mirrored = self.lastMirroredScrollY, abs(y - mirrored) < 2 { return }
                self.pendingScrollY = y
            }
            return .undefined
        }
        closures.append(scroll)
        _ = window.addEventListener("scroll", scroll)

        let keydown = JSClosure { [weak self] arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated { self?.handleKey(event) }
            return .undefined
        }
        closures.append(keydown)
        _ = window.addEventListener("keydown", keydown)

        let keyup = JSClosure { [weak self] arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated { self?.syncOverlayModifiers(event, isUp: true) }
            return .undefined
        }
        closures.append(keyup)
        _ = window.addEventListener("keyup", keyup)
    }

    private func handleKey(_ event: JSValue) {
        // ⌘/Ctrl + ↑/↓ jumps (animated) to the first / last slide; bare ↑/↓ step one.
        let jump = (event.metaKey.boolean ?? false) || (event.ctrlKey.boolean ?? false)
        switch event.key.string ?? "" {
        case "ArrowDown":
            _ = event.preventDefault()
            if jump { player.lastSlide() } else { player.nextSlide() }
        case "ArrowUp":
            _ = event.preventDefault()
            if jump { player.firstSlide() } else { player.previousSlide() }
        case "ArrowRight": _ = event.preventDefault(); player.nextStep()
        case "ArrowLeft": _ = event.preventDefault(); player.previousStep()
        case " ", "Spacebar": _ = event.preventDefault(); player.toggleAutoplay()  // play/pause
        default: break
        }
        syncOverlayModifiers(event, isUp: false)
    }

    /// Shift → index overlay; Option+Shift → the interactive (draggable /
    /// touchable) overlay. Recomputed from the live modifier flags so the modes
    /// hand off as Option is pressed or released under Shift.
    private func syncOverlayModifiers(_ event: JSValue, isUp: Bool) {
        guard syncsDebugOverlay else { return }   // editor hosts own Shift (multi-select)
        let shift = event.shiftKey.boolean ?? false
        let alt = event.altKey.boolean ?? false
        engine.isInteractiveOverlayActive = shift && alt
        engine.isDebugOverlayActive = shift && !alt
        if (event.key.string ?? "") == "Shift" {
            scene.dispatch(isUp ? .keyUp("Shift") : .keyDown("Shift"))
        }
    }

    /// Touch handling for the pinned canvas: flips `touch-action` (grab a token vs
    /// pan-scroll the page) and feeds a horizontal-swipe recognizer that drives
    /// step navigation. Listeners are independent of `InputBindings` (which owns
    /// drag dispatch) — these only read hit state and steer the player.
    private func installTouchGestures() {
        listen("pointerdown") { [weak self] event in self?.touchDown(event) }
        listen("pointermove") { [weak self] event in self?.touchMove(event) }
        listen("pointerup") { [weak self] event in self?.touchUp(event) }
        listen("pointercancel") { [weak self] _ in self?.touchCancel() }
    }

    private func listen(_ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
        let closure = JSClosure { arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated { handler(event) }
            return .undefined
        }
        closures.append(closure)
        _ = canvas.addEventListener(event, closure)
    }

    private func touchDown(_ event: JSValue) {
        let point = worldPoint(event)
        let grabbing = scene.drag.hitTestDraggable(at: point, in: scene)
        // Over a token → grab (no page scroll); empty canvas → pan-y (scroll-scrub).
        _ = canvas.setAttribute("style", "touch-action: \(grabbing ? "none" : "pan-y")")
        // Track a horizontal swipe only when it won't fight a drag or a live tween.
        swipeTracking = (event.pointerType.string ?? "") == "touch" && !grabbing && !player.isTweening
        if swipeTracking {
            // Threshold scales with the visible frame so a swipe reads the same at
            // any zoom; floored so a tight crop still needs a real flick.
            swipe.threshold = Swift.max(scene.size.x * 0.15, 0.5)
            swipe.begin(at: point)
        }
    }

    private func touchMove(_ event: JSValue) {
        guard swipeTracking else { return }
        swipe.move(to: worldPoint(event))
    }

    private func touchUp(_ event: JSValue) {
        guard swipeTracking else { return }
        swipeTracking = false
        switch swipe.end() {
        case .left: player.nextStep()        // swipe left → advance a step
        case .right: player.previousStep()   // swipe right → go back a step
        default: break                        // up/down/sub-threshold → leave to scroll/tap
        }
    }

    private func touchCancel() {
        swipeTracking = false
        swipe.cancel()
    }

    private func worldPoint(_ event: JSValue) -> Position {
        let rect = canvas.getBoundingClientRect()
        let width = Swift.max(rect.width.number ?? 1, 1)
        let height = Swift.max(rect.height.number ?? 1, 1)
        let x = ((event.clientX.number ?? 0) - (rect.left.number ?? 0)) / width
        let y = ((event.clientY.number ?? 0) - (rect.top.number ?? 0)) / height
        return scene.worldPosition(normalizedViewport: SIMD2(Real(x), Real(y)))
    }

    private func syncHUD() {
        guard hud.object != nil, story.slides.indices.contains(player.currentSlideIndex) else { return }
        let slide = story.slides[player.currentSlideIndex]
        hud.textContent = .string("\(slide.index + 1)/\(story.slides.count)  \(slide.title)")
    }

    /// Mirrors the active narration caption into the band, toggling `.show` so an
    /// empty caption fades the band out (CSS transition). Deduped on the last text
    /// so we touch the DOM only when the caption actually changes.
    private func syncCaption() {
        guard caption.object != nil else { return }
        let text = player.currentCaption
        guard text != lastCaption else { return }
        lastCaption = text
        caption.textContent = .string(text)
        caption.className = .string(text.isEmpty ? "" : "show")
    }
}
#endif
