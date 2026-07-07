// ArticleDOM — the WASI-only DOM renderer that walks a `Document` (the pure
// value model in ArticleDSL.swift) and builds real DOM nodes via JavaScriptKit.
// It is self-contained on styling: `render` injects the embedded stylesheet
// (ArticleStyle.css) into `<head>` itself, so the shell page carries no CSS —
// it only needs a mount element and MathJax.
//
// It never touches innerHTML for author text — every string goes through a text
// node (or a light *italic* / **bold** / `code` inline parse), so TeX backslashes
// and angle brackets survive verbatim; MathJax then typesets the `\(…\)` inline
// and `$$…$$` display delimiters left sitting in those text nodes.
//
// Each `presentation {}` block renders as an embedded Physica Story: a real
// WebGPU canvas driven by a `StoryPlayer` (see ArticleStoryDeck). `render` builds
// the article DOM synchronously, then — because booting a WebGPU renderer + font
// is async — awaits the deck boots after the article is mounted, returning an
// `ArticleMount` the caller retains for the page life.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

/// Retains everything a rendered article needs kept alive: event closures (deck
/// nav / dots) and the embedded story decks (each owns a renderer + rAF loop).
@MainActor
public final class ArticleMount {
    public let closures: [JSClosure]
    public let decks: [ArticleStoryDeck]
    init(closures: [JSClosure], decks: [ArticleStoryDeck]) {
        self.closures = closures
        self.decks = decks
    }
}

@MainActor
public enum ArticleDOM {
    /// Builds the whole article under `hostID` (cleared first), then boots each
    /// `presentation {}` block as an embedded Physica Story (titles use `font`).
    /// Returns an empty mount when there is no DOM (headless smoke).
    @discardableResult
    public static func render(
        _ document: Document, into hostID: String, font: Font? = nil
    ) async -> ArticleMount {
        guard let domObj = JSObject.global.document.object else {
            return ArticleMount(closures: [], decks: [])
        }
        var host = domObj.getElementById!(hostID)
        guard host.object != nil else { return ArticleMount(closures: [], decks: []) }
        host.innerHTML = .string("")

        ensureStyle(domObj)
        applyTheme(domObj, background: document.background)

        let ctx = Ctx(dom: domObj)

        // Pre-scan chapters so the sticky topbar can link to each §.
        var chapters: [(number: Int, title: String, id: String)] = []
        var scan = 0
        for section in document.sections {
            if case let .chapter(chapter) = section {
                scan += 1
                chapters.append((scan, chapter.title, chapter.id ?? "ch\(scan)"))
            }
        }

        _ = host.appendChild(buildTopbar(chapters, ctx: ctx))

        var article = ctx.el("article")
        article.className = .string("paper")

        var chapterNo = 0
        for section in document.sections {
            switch section {
            case let .title(title):
                renderTitle(title, to: article, ctx: ctx)
            case let .chapter(chapter):
                chapterNo += 1
                let anchor = chapter.id ?? "ch\(chapterNo)"
                renderChapter(chapter, number: chapterNo, anchor: anchor, to: article, ctx: ctx)
            case let .footer(lines):
                renderFooter(lines, to: article, ctx: ctx)
            }
        }

        _ = host.appendChild(article)

        // Now the canvases are live in the DOM — boot each deck's story.
        var decks: [ArticleStoryDeck] = []
        for pending in ctx.pendingDecks {
            if let deck = await ArticleStoryDeck.boot(pending, font: font) {
                decks.append(deck)
            }
        }
        return ArticleMount(closures: ctx.closures, decks: decks)
    }

    // MARK: Embedded stylesheet

    /// Injects `ArticleStyle.css` as a `<style>` in `<head>` once. Idempotent —
    /// a second `render` (e.g. re-mount) finds the element by id and skips it.
    private static func ensureStyle(_ dom: JSObject) {
        if dom.getElementById!(ArticleStyle.elementID).object != nil { return }
        var style = dom.createElement!("style")
        style.id = .string(ArticleStyle.elementID)
        style.textContent = .string(ArticleStyle.css)
        var head = dom.head
        if head.object != nil {
            _ = head.appendChild(style)
        } else {
            var root = dom.documentElement
            if root.object != nil { _ = root.appendChild(style) }
        }
    }

    /// Upserts the theme-override `<style>` for `Document(background:)`, after
    /// the base sheet so its `:root` wins. The default `.documentLight` emits
    /// nothing (the base sheet's hand-tuned constants stay authoritative — and
    /// the stock article stays byte-identical); a re-render with a different
    /// background updates the element in place, so themes can switch.
    private static func applyTheme(_ dom: JSObject, background: Color) {
        let override = background == .documentLight
            ? "" : ArticleStyle.theme(background: background)
        var existing = dom.getElementById!(ArticleStyle.themeElementID)
        if existing.object != nil {
            existing.textContent = .string(override)
            return
        }
        guard !override.isEmpty else { return }
        var style = dom.createElement!("style")
        style.id = .string(ArticleStyle.themeElementID)
        style.textContent = .string(override)
        var head = dom.head
        if head.object != nil {
            _ = head.appendChild(style)
        } else {
            var root = dom.documentElement
            if root.object != nil { _ = root.appendChild(style) }
        }
    }

    // MARK: Topbar

    private static func buildTopbar(
        _ chapters: [(number: Int, title: String, id: String)], ctx: Ctx
    ) -> JSValue {
        var bar = ctx.el("div"); bar.className = .string("topbar")
        var row = ctx.el("div"); row.className = .string("row")

        var brand = ctx.el("span"); brand.className = .string("brand")
        _ = brand.appendChild(ctx.textNode("Phys"))
        var brandB = ctx.el("b"); brandB.textContent = .string("ica")
        _ = brand.appendChild(brandB)
        _ = row.appendChild(brand)

        var sub = ctx.el("span"); sub.className = .string("sub")
        sub.textContent = .string("/ rigid-body integrator")
        _ = row.appendChild(sub)

        var nav = ctx.el("nav")
        for chapter in chapters {
            var link = ctx.el("a")
            _ = link.setAttribute("href", "#\(chapter.id)")
            link.textContent = .string("§\(chapter.number)")
            _ = nav.appendChild(link)
        }
        _ = row.appendChild(nav)

        _ = bar.appendChild(row)
        return bar
    }

    // MARK: Title / header

    private static func renderTitle(_ title: TitleBlock, to parent: JSValue, ctx: Ctx) {
        if let eyebrow = title.eyebrow {
            var e = ctx.el("p"); e.className = .string("eyebrow")
            e.textContent = .string(eyebrow)
            _ = parent.appendChild(e)
        }

        var h1 = ctx.el("h1"); h1.textContent = .string(title.headline)
        _ = parent.appendChild(h1)

        if let subtitle = title.subtitle {
            var e = ctx.el("p"); e.className = .string("subtitle")
            e.textContent = .string(subtitle)
            _ = parent.appendChild(e)
        }

        if let byline = title.byline {
            var wrap = ctx.el("div"); wrap.className = .string("byline")
            var avatar = ctx.el("span"); avatar.className = .string("avatar")
            avatar.textContent = .string(byline.avatar)
            _ = wrap.appendChild(avatar)
            var who = ctx.el("span"); who.className = .string("who")
            var nm = ctx.el("span"); nm.className = .string("nm")
            nm.textContent = .string(byline.name)
            _ = who.appendChild(nm)
            var meta = ctx.el("span"); meta.className = .string("meta2")
            meta.textContent = .string(byline.meta)
            _ = who.appendChild(meta)
            _ = wrap.appendChild(who)
            _ = parent.appendChild(wrap)
        }

        if let abstract = title.abstract {
            var e = ctx.el("p"); e.className = .string("abstract")
            ctx.appendInline(abstract, to: e)
            _ = parent.appendChild(e)
        }

        if !title.stats.isEmpty {
            var stats = ctx.el("div"); stats.className = .string("stats")
            for stat in title.stats {
                var chip = ctx.el("div"); chip.className = .string("stat")
                var b = ctx.el("b"); b.textContent = .string(stat.value)
                _ = chip.appendChild(b)
                var span = ctx.el("span"); span.textContent = .string(stat.label)
                _ = chip.appendChild(span)
                _ = stats.appendChild(chip)
            }
            _ = parent.appendChild(stats)
        }
    }

    // MARK: Chapter (§-numbered h2 + flow content)

    private static func renderChapter(
        _ chapter: ChapterBlock, number: Int, anchor: String, to parent: JSValue, ctx: Ctx
    ) {
        var h2 = ctx.el("h2"); h2.id = .string(anchor)
        var sec = ctx.el("span"); sec.className = .string("sec")
        sec.textContent = .string("§\(number)")
        _ = h2.appendChild(sec)
        _ = h2.appendChild(ctx.textNode(chapter.title))
        _ = parent.appendChild(h2)

        for block in chapter.blocks {
            renderBlock(block, to: parent, ctx: ctx)
        }
    }

    // MARK: Flow blocks

    private static func renderBlock(_ block: Block, to parent: JSValue, ctx: Ctx) {
        switch block {
        case let .paragraph(text):
            var p = ctx.el("p")
            if !text.isEmpty { ctx.appendInline(text, to: p) }
            _ = parent.appendChild(p)

        case let .headline(text):
            var h = ctx.el("h3"); h.textContent = .string(text)
            _ = parent.appendChild(h)

        case let .subheadline(text):
            var h = ctx.el("h4"); h.textContent = .string(text)
            _ = parent.appendChild(h)

        case let .math(kind, tag, tex):
            var wrap = ctx.el("div"); wrap.className = .string("mathblock")
            var body = tex
            if kind == .equation {
                ctx.eq += 1
                body += "\\tag{\(ctx.eq)}"
                if let tag { _ = wrap.setAttribute("data-tag", tag) }
            }
            // Display delimiters left for MathJax to typeset on the text node.
            wrap.textContent = .string("$$" + body + "$$")
            _ = parent.appendChild(wrap)

        case let .procedure(spec):
            _ = parent.appendChild(buildProcedure(spec, ctx: ctx))

        case let .table(spec):
            _ = parent.appendChild(buildTable(spec, ctx: ctx))

        case let .presentation(slides):
            _ = parent.appendChild(buildDeck(slides, ctx: ctx))

        case let .notation(rows):
            _ = parent.appendChild(buildNotation(rows, ctx: ctx))
        }
    }

    // MARK: Procedure float

    private static func buildProcedure(_ spec: ProcedureBlock, ctx: Ctx) -> JSValue {
        var box = ctx.el("div"); box.className = .string("procedure")

        var cap = ctx.el("div"); cap.className = .string("cap")
        var k = ctx.el("span"); k.className = .string("k")
        var kEm = ctx.el("em"); kEm.textContent = .string(spec.name)
        _ = k.appendChild(kEm)
        _ = cap.appendChild(k)
        var ttl = ctx.el("span"); ttl.className = .string("ttl")
        ctx.appendInline(spec.title, to: ttl)
        _ = cap.appendChild(ttl)
        _ = box.appendChild(cap)

        if let input = spec.input {
            _ = box.appendChild(buildIO(label: "Input", value: input, ctx: ctx))
        }
        if let output = spec.output {
            _ = box.appendChild(buildIO(label: "Output", value: output, ctx: ctx))
        }

        var ol = ctx.el("ol")
        for line in spec.lines {
            var li = ctx.el("li")
            if line.isReturn { li.className = .string("ret") }
            if line.isReturn {
                // The ::before glyph already renders "return"; keep the text plain.
                _ = li.appendChild(ctx.textNode("return "))
            }
            ctx.appendInline(line.text, to: li)
            if let note = line.note {
                var cm = ctx.el("span"); cm.className = .string("cm")
                ctx.appendInline(note, to: cm)
                _ = li.appendChild(ctx.textNode(" "))
                _ = li.appendChild(cm)
            }
            _ = ol.appendChild(li)
        }
        _ = box.appendChild(ol)

        if let foot = spec.foot {
            var f = ctx.el("p"); f.className = .string("foot")
            ctx.appendInline(foot, to: f)
            _ = box.appendChild(f)
        }
        return box
    }

    private static func buildIO(label: String, value: String, ctx: Ctx) -> JSValue {
        var io = ctx.el("div"); io.className = .string("io")
        var b = ctx.el("b"); b.textContent = .string(label)
        _ = io.appendChild(b)
        ctx.appendInline(value, to: io)
        return io
    }

    // MARK: Table (grid mixing math + text cells)

    private static func buildTable(_ spec: TableBlock, ctx: Ctx) -> JSValue {
        var table = ctx.el("div")
        let sepClass: String
        switch spec.separator {
        case .row: sepClass = "sep-row"
        case .column: sepClass = "sep-col"
        case .grid: sepClass = "sep-grid"
        case .none: sepClass = "sep-none"
        }
        table.className = .string("dtable \(sepClass)")
        let cols = max(1, spec.columns)
        table.style.gridTemplateColumns = .string("repeat(\(cols), minmax(0, 1fr))")
        for cell in spec.cells {
            var div = ctx.el("div"); div.className = .string("dcell")
            switch cell {
            case let .math(tex):
                // Inline delimiters so the cell sits on the text baseline.
                _ = div.classList.add("dcell-math")
                _ = div.appendChild(ctx.textNode("\\(" + tex + "\\)"))
            case let .text(text):
                if !text.isEmpty { ctx.appendInline(text, to: div) }
            }
            _ = table.appendChild(div)
        }
        return table
    }

    // MARK: Notation grid

    private static func buildNotation(_ rows: [NotationRow], ctx: Ctx) -> JSValue {
        var grid = ctx.el("div"); grid.className = .string("notation")
        for row in rows {
            var wrap = ctx.el("div")   // display:contents — lets dt/dd land on the grid
            var dt = ctx.el("dt")
            _ = dt.appendChild(ctx.textNode(row.symbol))   // symbol carries \(…\) inline math
            _ = wrap.appendChild(dt)
            var dd = ctx.el("dd")
            ctx.appendInline(row.definition, to: dd)
            _ = wrap.appendChild(dd)
            _ = grid.appendChild(wrap)
        }
        return grid
    }

    // MARK: Presentation deck (embedded Physica Story scaffold)

    /// Builds the DOM shell for an embedded story — a dark stage holding a WebGPU
    /// `<canvas>` + caption band, plus a nav row (Back / dots / Next / counter) —
    /// and registers a `PendingDeck` so `render` can boot the story once the
    /// canvas is live in the document. The story itself (scene, slides, player,
    /// renderer, rAF loop) is wired by `ArticleStoryDeck.boot`.
    private static func buildDeck(_ slides: [DeckSlide], ctx: Ctx) -> JSValue {
        ctx.deckSeq += 1
        let base = "article-story-\(ctx.deckSeq)"
        let canvasID = base
        let captionID = base + "-cap"
        let stageID = base + "-stage"
        let prevID = base + "-prev"
        let nextID = base + "-next"
        let countID = base + "-count"

        var deck = ctx.el("div"); deck.className = .string("story-deck")

        var stage = ctx.el("div"); stage.className = .string("story-stage")
        stage.id = .string(stageID)
        _ = stage.setAttribute("tabindex", "0")
        var canvas = ctx.el("canvas"); canvas.className = .string("story-canvas")
        canvas.id = .string(canvasID)
        _ = stage.appendChild(canvas)
        var caption = ctx.el("div"); caption.className = .string("story-deck-caption")
        caption.id = .string(captionID)
        _ = stage.appendChild(caption)
        _ = deck.appendChild(stage)

        var nav = ctx.el("div"); nav.className = .string("deck-nav")
        var prev = ctx.el("button"); prev.className = .string("deck-btn")
        prev.id = .string(prevID); prev.textContent = .string("‹ Back")
        var dotsWrap = ctx.el("div"); dotsWrap.className = .string("deck-dots")
        var dotIDs: [String] = []
        for index in slides.indices {
            let dotID = base + "-dot-\(index)"
            var dot = ctx.el("button")
            dot.className = .string(index == 0 ? "deck-dot active" : "deck-dot")
            dot.id = .string(dotID)
            _ = dot.setAttribute("aria-label", "Slide \(index + 1)")
            _ = dotsWrap.appendChild(dot)
            dotIDs.append(dotID)
        }
        var next = ctx.el("button"); next.className = .string("deck-btn")
        next.id = .string(nextID); next.textContent = .string("Next ›")
        var counter = ctx.el("span"); counter.className = .string("deck-count")
        counter.id = .string(countID)
        counter.textContent = .string("1 / \(max(1, slides.count))")

        _ = nav.appendChild(prev)
        _ = nav.appendChild(dotsWrap)
        _ = nav.appendChild(next)
        _ = nav.appendChild(counter)
        _ = deck.appendChild(nav)

        ctx.pendingDecks.append(PendingDeck(
            slides: slides, canvasID: canvasID, captionID: captionID, stageID: stageID,
            prevID: prevID, nextID: nextID, countID: countID, dotIDs: dotIDs
        ))
        return deck
    }

    // MARK: Footer

    private static func renderFooter(_ lines: [String], to parent: JSValue, ctx: Ctx) {
        var footer = ctx.el("footer"); footer.className = .string("foot")
        for (index, line) in lines.enumerated() {
            if index > 0 { _ = footer.appendChild(ctx.el("br")) }
            ctx.appendInline(line, to: footer)
        }
        _ = parent.appendChild(footer)
    }
}

// MARK: - Pending deck (an unbuilt embedded story, boot after the DOM is mounted)

/// The DOM ids `buildDeck` minted for one `presentation {}` block, handed to
/// `ArticleStoryDeck.boot` once the canvas is live in the document.
@MainActor
struct PendingDeck {
    let slides: [DeckSlide]
    let canvasID: String
    let captionID: String
    let stageID: String
    let prevID: String
    let nextID: String
    let countID: String
    let dotIDs: [String]
}

// MARK: - Rendering context (element factory + inline markup)

@MainActor
private final class Ctx {
    let dom: JSObject
    var closures: [JSClosure] = []
    var eq = 0
    /// Presentation blocks discovered during the DOM walk, booted after mount.
    var pendingDecks: [PendingDeck] = []
    var deckSeq = 0

    init(dom: JSObject) { self.dom = dom }

    func el(_ tag: String) -> JSValue { dom.createElement!(tag) }
    func textNode(_ s: String) -> JSValue { dom.createTextNode!(s) }

    /// Appends `text` to `parent` via the shared inline markdown + math renderer.
    func appendInline(_ text: String, to parent: JSValue) {
        ArticleInline.append(text, to: parent, using: dom)
    }
}
#endif
