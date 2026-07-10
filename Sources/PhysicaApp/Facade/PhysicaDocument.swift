// PhysicaDocument — the native document facade, the article sibling of
// `PhysicaApplication`. It wraps the platform-neutral `Document` DSL (the same
// one the web `Document("…") { … }` auto-mount uses) and presents it one of two
// ways off the one declaration — no wasm, no browser bundle:
//
//     let doc = PhysicaDocument("Physics · Rigid bodies") {
//         Title("A rigid body, integrated the Hamiltonian way", … )
//         Chapter("The state you store", id: "state") { … }
//     }
//     doc.run()                                        // window (WKWebView)
//     try doc.write(to: URL(fileURLWithPath: "a.html"))  // single self-contained file
//
// Both render the same `ArticleHTML` string — the embedded stylesheet + a CDN
// MathJax loader — so the math typesets whether the page is opened in a browser
// or shown in the in-app WebView. `background: .documentDark` flips it to the
// dark palette, exactly like the web facade.
//
// A `presentation {}` deck has no static form, so each presentation is realized
// natively (see `DocumentDeck`): `run()` floats a live Metal view over the deck's
// slot in the article (`DeckOverlayController`), while `write(to:)` bakes the
// deck to a short movie and embeds it as a base64 `<video>` in the file.

import PhysicaFoundation
import PhysicaKernel
import PhysicaArticle

#if os(macOS)
import Foundation
import AppKit
import WebKit

public struct PhysicaDocument {
    private let document: Document

    /// Builds the article value from the `@DocumentBuilder` body. Pure — nothing
    /// is rendered, written, or shown until `run()` / `write(to:)`.
    public init(
        _ title: String = "",
        background: Color = .documentLight,
        @DocumentBuilder _ content: () -> [Section]
    ) {
        self.document = Document(title, background: background, content)
    }

    /// Presents the article in a native window — an `NSWindow` hosting a
    /// `WKWebView` that renders the same self-contained HTML `write(to:)`
    /// produces (WebKit, not wasm). Blocks in `NSApp.run()`, the article sibling
    /// of `PhysicaApplication.run()`.
    @MainActor
    public func run(size: CGSize = CGSize(width: 940, height: 1040)) {
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)

        // Presentation decks render as native Metal overlays floated over slot
        // <div>s in the article; their scenes need the author faces first.
        PhysicaApplication.installDefaultFonts()
        let decks = DocumentDeck.decks(in: document)

        // When the article carries decks, wire the reporter script + this
        // controller into the web view's content controller *before* it is built,
        // and emit a slot placeholder for each deck (else the static outline).
        let configuration = WKWebViewConfiguration()
        var overlayController: DeckOverlayController?
        var deckOverrides: [Int: String] = [:]
        if !decks.isEmpty {
            let controller = DeckOverlayController(decks: decks, font: FontBook.resolve(.body).font)
            let userContent = configuration.userContentController
            userContent.addUserScript(WKUserScript(
                source: DeckOverlayController.reporterJS,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true
            ))
            userContent.add(controller, name: DeckOverlayController.messageName)
            overlayController = controller
            for index in decks.indices { deckOverrides[index] = Self.deckSlotHTML(index: index) }
        }

        let webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)

        // Host the web view and the deck panes as siblings in a plain container:
        // the panes float over the (viewport-fixed) web view and are repositioned
        // on scroll from the reporter's rects — never reparented into the web
        // view's scroll area, so they track the article instead of drifting.
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        overlayController?.attach(to: webView, host: container)

        // A real https base URL gives the page a secure origin, so the absolute
        // MathJax CDN <script> loads (a nil base is opaque `about:blank`, which
        // blocks the remote fetch and leaves the TeX un-typeset).
        webView.loadHTMLString(
            ArticleHTML.render(document, deckOverrides: deckOverrides),
            baseURL: URL(string: "https://physica.local/")
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = document.title.isEmpty ? "Physica" : document.title
        window.contentView = container
        window.center()

        AppRoots.installQuitMenu(application)   // minimal main menu (Quit ⌘Q), no nib

        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        AppRoots.keep(window)
        if let overlayController { AppRoots.keep(overlayController) }
        application.run()
    }

    /// Serializes the article to a single self-contained HTML file at `url`
    /// (`ArticleHTML.render`), creating or overwriting it. Any `presentation {}`
    /// deck is rendered to a short H.264 movie (`deckSize` at `deckFPS`) and
    /// embedded as a base64 `<video>`, so the written file plays the deck without
    /// wasm; a deck falls back to its static outline if Metal is unavailable.
    @MainActor
    public func write(
        to url: URL,
        deckSize: CGSize = CGSize(width: 960, height: 540),
        deckFPS: Int = 30
    ) throws {
        PhysicaApplication.installDefaultFonts()
        let font = FontBook.resolve(.body).font
        var deckOverrides: [Int: String] = [:]
        for (index, slides) in DocumentDeck.decks(in: document).enumerated() {
            if let markup = DocumentDeck.videoMarkup(for: slides, font: font, size: deckSize, fps: deckFPS) {
                deckOverrides[index] = markup
            }
        }
        try Data(ArticleHTML.render(document, deckOverrides: deckOverrides).utf8).write(to: url)
    }

    /// The serialized HTML, if a caller wants the string instead of a file. Decks
    /// render as their static outline here — the live/video realizations need the
    /// windowed `run()` or the file-writing `write(to:)`.
    public func html() -> String {
        ArticleHTML.render(document)
    }

    /// The placeholder a live Metal deck floats over in `run()`: a full-width 16:9
    /// dark box (so there's no flash before the overlay lands over it). Tagged
    /// `data-deck` with the deck's document-order index so the reporter script can
    /// name it back to the matching pane.
    private static func deckSlotHTML(index: Int) -> String {
        "<div class=\"physica-deck-slot\" data-deck=\"\(index)\""
            + " style=\"width:100%;aspect-ratio:16/9;margin:1.8em 0;border-radius:12px;background:#12141a\"></div>"
    }
}
#endif
