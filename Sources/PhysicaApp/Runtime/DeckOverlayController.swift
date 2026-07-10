// DeckOverlayController — floats live Metal deck panes over the article's
// presentation slots in `PhysicaDocument.run()`. The article is a `WKWebView`
// rendering the static HTML; each `presentation {}` deck emits a
// `<div class="physica-deck-slot">` placeholder (see `PhysicaDocument`), and this
// controller pins a native `MTKView` over each slot, kept in place as the reader
// scrolls.
//
// How the pinning stays honest: a small injected script (`reporterJS`) posts
// every slot's viewport rect to the native side on load / scroll / resize /
// reflow (and after MathJax typesets, which shifts layout). Each message
// repositions the matching pane and shows/ticks it only while its slot is on
// screen — the native mirror of the web deck's `VisibilityObserver`.
//
// Degrades: if Metal is unavailable no panes are built, the slots stay empty
// (dark boxes), and the article still reads.

import PhysicaFoundation
import PhysicaKernel

#if os(macOS)
import AppKit
import WebKit
import MetalKit
import QuartzCore

@MainActor
final class DeckOverlayController: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// The message-handler name the reporter posts slot rects to.
    static let messageName = "physicaDeck"

    /// Injected at document end: reports every deck slot's viewport rect to the
    /// native side whenever layout could have moved it. Rects are in CSS px
    /// (top-left origin) — the controller flips them into the web view's AppKit
    /// coordinate space.
    static let reporterJS = #"""
    (function () {
      function report() {
        var slots = document.querySelectorAll('.physica-deck-slot');
        var out = [];
        for (var i = 0; i < slots.length; i++) {
          var el = slots[i];
          var r = el.getBoundingClientRect();
          out.push({
            index: parseInt(el.getAttribute('data-deck') || '0', 10),
            x: r.left, y: r.top, w: r.width, h: r.height,
            visible: r.bottom > 0 && r.top < window.innerHeight
          });
        }
        window.webkit.messageHandlers.physicaDeck.postMessage(out);
      }
      window.__physicaDeckReport = report;
      window.addEventListener('scroll', report, { passive: true });
      window.addEventListener('resize', report);
      window.addEventListener('load', report);
      if (window.MathJax && MathJax.startup && MathJax.startup.promise) {
        MathJax.startup.promise.then(report).catch(function () {});
      }
      if (window.ResizeObserver) { new ResizeObserver(report).observe(document.body); }
      report();
    })();
    """#

    private let decks: [[DeckSlide]]
    private let font: Font?
    private weak var webView: WKWebView?
    private var panes: [Int: DeckPane] = [:]

    init(decks: [[DeckSlide]], font: Font?) {
        self.decks = decks
        self.font = font
        super.init()
    }

    /// Builds a pane per deck and floats each over the web content as a **sibling**
    /// of the web view inside `host` (the window's content container) — not a web-
    /// view subview, whose scroll/flip semantics are murky. Called once, after the
    /// web view (whose configuration already carries `reporterJS` and this
    /// controller as the `messageName` handler) exists.
    func attach(to webView: WKWebView, host: NSView) {
        self.webView = webView
        webView.navigationDelegate = self
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Physica: Metal unavailable — presentation decks stay empty")
            return
        }
        for (index, slides) in decks.enumerated() {
            guard let pane = DeckPane(index: index, slides: slides, font: font, device: device, webView: webView)
            else { continue }
            panes[index] = pane
            host.addSubview(pane.view)   // above the web view (added earlier)
        }
    }

    // MARK: Slot rects → pane frames

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.messageName,
              let slots = message.body as? [[String: Any]] else { return }
        for slot in slots {
            guard let index = (slot["index"] as? NSNumber)?.intValue, let pane = panes[index] else { continue }
            let rect = CGRect(
                x: (slot["x"] as? NSNumber)?.doubleValue ?? 0,
                y: (slot["y"] as? NSNumber)?.doubleValue ?? 0,
                width: (slot["w"] as? NSNumber)?.doubleValue ?? 0,
                height: (slot["h"] as? NSNumber)?.doubleValue ?? 0
            )
            let visible = (slot["visible"] as? NSNumber)?.boolValue ?? false
            pane.layout(to: rect, visible: visible)
        }
    }

    // MARK: Navigation — re-report once the page settles

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("window.__physicaDeckReport && window.__physicaDeckReport()")
    }
}

// MARK: - One live deck

/// A single deck's floating canvas: an `MTKView` driven by a `StoryPlayer`, with
/// ‹ / › nav buttons and a slide counter. Ticks (and renders) only while its slot
/// is on screen; forwards scroll to the article so the page still scrolls when the
/// pointer is over the deck.
@MainActor
final class DeckPane: NSObject, MTKViewDelegate {
    let index: Int
    let view: DeckMetalView

    private let engine: Engine
    private let scene: Scene
    private let story: Story
    private let player: StoryPlayer
    private let renderer: MetalRenderer

    private let counter: NSTextField
    private let prevButton: NSButton
    private let nextButton: NSButton

    private var clock = FrameClock()
    private var revealed = false
    private var lastCounter = ""   // skip redundant per-frame counter writes

    init?(index: Int, slides: [DeckSlide], font: Font?, device: MTLDevice, webView: WKWebView) {
        guard let renderer = try? MetalRenderer(device: device) else { return nil }
        self.index = index
        self.renderer = renderer

        let engine = Engine()
        self.engine = engine
        self.story = DocumentDeck.buildStory(slides, font: font, engine: engine)
        self.scene = story.scene
        self.player = StoryPlayer(story: story)

        let view = DeckMetalView(frame: .zero, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.sampleCount = 4
        view.preferredFramesPerSecond = 60
        view.isPaused = true            // ticks only while on screen
        view.isHidden = true            // shown on the first visible slot rect
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        view.layer?.masksToBounds = true
        view.webView = webView
        self.view = view

        counter = DeckPane.makeCounter()
        prevButton = DeckPane.makeNavButton("‹")
        nextButton = DeckPane.makeNavButton("›")

        super.init()

        engine.bind(renderer, to: scene)
        renderer.currentView = view
        view.delegate = self

        prevButton.target = self; prevButton.action = #selector(goPrev)
        nextButton.target = self; nextButton.action = #selector(goNext)
        for control in [counter, prevButton, nextButton] as [NSView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        NSLayoutConstraint.activate([
            prevButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            prevButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            nextButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            nextButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            counter.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            counter.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        syncChrome()
    }

    /// Pins the pane over `rect` and ticks it only while visible. The first
    /// visible layout reveals slide 0.
    ///
    /// `rect` is viewport-relative CSS px (top-left origin). The pane is a sibling
    /// of the web view inside the window's content container, so map into the
    /// host's space honoring `host.isFlipped` — a bare `NSView` container is
    /// bottom-left (flip Y), and this stays correct even if a caller hosts the
    /// pane somewhere top-left. (The earlier bug: treating a top-left web-view
    /// subview as bottom-left inverted the vertical scroll tracking.)
    func layout(to rect: CGRect, visible: Bool) {
        guard visible, rect.width > 1, rect.height > 1, let host = view.superview else {
            view.isHidden = true
            view.isPaused = true
            return
        }
        let originY = host.isFlipped
            ? rect.origin.y
            : host.bounds.height - rect.origin.y - rect.height
        view.frame = CGRect(x: rect.origin.x, y: originY, width: rect.width, height: rect.height)
        if view.isHidden {
            view.isHidden = false
            clock.reset()   // no giant first dt after being hidden
        }
        view.isPaused = false
        if !revealed {
            revealed = true
            // Just shy of slide 0's end so the index (and counter) stays 0.
            player.scrub(slide: 0, progress: 0.995)
        }
    }

    // MARK: Frame loop

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            let deltaTime = clock.tick()
            renderer.currentView = view
            player.tick(deltaTime: deltaTime)   // advances an in-flight arrow tween
            engine.tick(deltaTime: deltaTime)   // updates + renders the bound scene
            syncChrome()
        }
    }

    // MARK: Nav chrome

    @objc private func goPrev() { player.previousStep(); syncChrome() }
    @objc private func goNext() { player.nextStep(); syncChrome() }

    private func syncChrome() {
        let total = max(story.slides.count, 1)
        let text = "\(player.currentSlideIndex + 1) / \(total)"
        guard text != lastCounter else { return }   // skip per-frame relayout when unchanged
        counter.stringValue = text
        lastCounter = text
    }

    private static func makeNavButton(_ glyph: String) -> NSButton {
        let button = NSButton(title: glyph, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 15, weight: .semibold)
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private static func makeCounter() -> NSTextField {
        let field = NSTextField(labelWithString: "1 / 1")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .white
        field.alignment = .center
        return field
    }
}

// MARK: - The floating MTKView

/// The deck's canvas. Not flipped (AppKit bottom-left, matching the frame math in
/// `DeckPane.layout`). Forwards vertical scroll to the article via JS so a reader
/// whose pointer is over the deck can still scroll the page; the reporter then
/// repositions the pane. Accepts first mouse so the nav buttons click through
/// without a focus round-trip.
@MainActor
final class DeckMetalView: MTKView {
    weak var webView: WKWebView?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let webView else { return }
        // Precise (trackpad) deltas are already in points; legacy line deltas need
        // scaling to feel right. Negate so content tracks the gesture direction.
        let delta = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 16
        webView.evaluateJavaScript("window.scrollBy(0, \(-delta))")
    }
}
#endif
