// ArticleHTML — the platform-neutral static serializer: it walks a `Document`
// (the same value model `ArticleDOM` walks) and returns ONE self-contained HTML
// string. No JavaScriptKit, no DOM, no wasm — pure string building — so a native
// or host tool can write a shareable `.html` file (see `PhysicaDocument.write`).
//
// It mirrors `ArticleDOM` element-for-element and class-for-class, so the static
// page and the live DOM render identically under the same embedded stylesheet
// (`ArticleStyle.css`) and the same MathJax config. Two deliberate divergences,
// both because the file is meant to open standalone rather than inside the COEP
// dev server: the embedded `<style>`/theme + a CDN MathJax `<script>` are baked
// into `<head>` (the shell page carries neither), and figure `<img>`s are NOT
// `crossorigin` (so local/relative sources load off `file://`). A `presentation
// {}` deck — an embedded live WebGPU story — has no static form, so it degrades
// to its slide titles + caption prose.

import PhysicaFoundation

public enum ArticleHTML {
    /// Serializes `document` to a complete `<!doctype html>` page.
    ///
    /// `deckOverrides` maps a `presentation {}` deck's **document-order index**
    /// (0-based, counting every presentation block in reading order) to a block of
    /// HTML to emit in that deck's place — instead of the static title+caption
    /// outline. The native facade uses this to drop in a live-deck slot `<div>`
    /// the app floats a Metal view over (`PhysicaDocument.run`) or a base64
    /// `<video>` embed (`PhysicaDocument.write`); a deck with no override still
    /// renders the static outline, so pure-string callers pass nothing.
    public static func render(_ document: Document, deckOverrides: [Int: String] = [:]) -> String {
        var builder = Builder(deckOverrides: deckOverrides)
        builder.emit(document)
        return builder.out
    }
}

// MARK: - Builder (accumulates the page; carries the equation counter)

private struct Builder {
    var out = ""
    var eq = 0
    /// Per-deck HTML overrides (see `ArticleHTML.render`), consumed in document
    /// order by `deckOrdinal`.
    var deckOverrides: [Int: String] = [:]
    var deckOrdinal = 0

    mutating func emit(_ document: Document) {
        let pageTitle = document.title.isEmpty ? "Physica" : document.title
        out += "<!doctype html>\n<html lang=\"en\">\n<head>\n"
        out += "<meta charset=\"utf-8\">\n"
        out += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        out += "<title>\(escape(pageTitle))</title>\n"
        out += "<style id=\"\(ArticleStyle.elementID)\">\n\(ArticleStyle.css)\n</style>\n"
        if document.background != .documentLight {
            out += "<style id=\"\(ArticleStyle.themeElementID)\">\n"
            out += ArticleStyle.theme(background: document.background)
            out += "\n</style>\n"
        }
        out += mathJaxHead
        out += "</head>\n<body>\n"

        out += topbar(scanChapters(document))

        out += "<article class=\"paper\">\n"
        var chapterNo = 0
        for section in document.sections {
            switch section {
            case let .title(title):
                emitTitle(title)
            case let .chapter(chapter):
                chapterNo += 1
                emitChapter(chapter, number: chapterNo, anchor: chapter.id ?? "ch\(chapterNo)")
            case let .footer(lines):
                emitFooter(lines)
            }
        }
        out += "</article>\n</body>\n</html>\n"
    }

    // MARK: Topbar (mirrors ArticleDOM.buildTopbar)

    private func scanChapters(_ document: Document) -> [(number: Int, title: String, id: String)] {
        var chapters: [(number: Int, title: String, id: String)] = []
        var scan = 0
        for section in document.sections {
            if case let .chapter(chapter) = section {
                scan += 1
                chapters.append((scan, chapter.title, chapter.id ?? "ch\(scan)"))
            }
        }
        return chapters
    }

    private func topbar(_ chapters: [(number: Int, title: String, id: String)]) -> String {
        var bar = "<div class=\"topbar\"><div class=\"row\">"
        bar += "<span class=\"brand\">Phys<b>ica</b></span>"
        bar += "<span class=\"sub\">/ rigid-body integrator</span>"
        bar += "<nav>"
        for chapter in chapters {
            bar += "<a href=\"#\(attr(chapter.id))\">§\(chapter.number)</a>"
        }
        bar += "</nav></div></div>\n"
        return bar
    }

    // MARK: Title / header (mirrors ArticleDOM.renderTitle)

    mutating func emitTitle(_ title: TitleBlock) {
        if let eyebrow = title.eyebrow {
            out += "<p class=\"eyebrow\">\(escape(eyebrow))</p>\n"
        }
        out += "<h1>\(escape(title.headline))</h1>\n"
        if let subtitle = title.subtitle {
            out += "<p class=\"subtitle\">\(escape(subtitle))</p>\n"
        }
        if let byline = title.byline {
            out += "<div class=\"byline\"><span class=\"avatar\">\(escape(byline.avatar))</span>"
            out += "<span class=\"who\"><span class=\"nm\">\(escape(byline.name))</span>"
            out += "<span class=\"meta2\">\(escape(byline.meta))</span></span></div>\n"
        }
        if let abstract = title.abstract {
            out += "<p class=\"abstract\">\(inline(abstract))</p>\n"
        }
        if !title.stats.isEmpty {
            out += "<div class=\"stats\">"
            for stat in title.stats {
                out += "<div class=\"stat\"><b>\(escape(stat.value))</b><span>\(escape(stat.label))</span></div>"
            }
            out += "</div>\n"
        }
    }

    // MARK: Chapter (mirrors ArticleDOM.renderChapter)

    mutating func emitChapter(_ chapter: ChapterBlock, number: Int, anchor: String) {
        out += "<h2 id=\"\(attr(anchor))\"><span class=\"sec\">§\(number)</span>\(escape(chapter.title))</h2>\n"
        for block in chapter.blocks { emitBlock(block) }
    }

    // MARK: Flow blocks (mirrors ArticleDOM.renderBlock)

    mutating func emitBlock(_ block: Block) {
        switch block {
        case let .paragraph(text):
            out += "<p>\(text.isEmpty ? "" : inline(text))</p>\n"

        case let .headline(text):
            out += "<h3>\(escape(text))</h3>\n"

        case let .subheadline(text):
            out += "<h4>\(escape(text))</h4>\n"

        case let .math(kind, tag, tex):
            var body = tex
            var tagAttr = ""
            if kind == .equation {
                eq += 1
                body += "\\tag{\(eq)}"
                if let tag { tagAttr = " data-tag=\"\(attr(tag))\"" }
            }
            out += "<div class=\"mathblock\"\(tagAttr)>\(escape("$$" + body + "$$"))</div>\n"

        case let .procedure(spec):
            emitProcedure(spec)

        case let .table(spec):
            emitTable(spec)

        case let .figure(spec):
            emitFigure(spec)

        case let .presentation(slides):
            emitPresentation(slides)

        case let .notation(rows):
            emitNotation(rows)
        }
    }

    // MARK: Procedure float (mirrors ArticleDOM.buildProcedure)

    mutating func emitProcedure(_ spec: ProcedureBlock) {
        out += "<div class=\"procedure\">"
        out += "<div class=\"cap\"><span class=\"k\"><em>\(escape(spec.name))</em></span>"
        out += "<span class=\"ttl\">\(inline(spec.title))</span></div>"
        if let input = spec.input { out += io("Input", input) }
        if let output = spec.output { out += io("Output", output) }
        out += "<ol>"
        for line in spec.lines {
            out += line.isReturn ? "<li class=\"ret\">return " : "<li>"
            out += inline(line.text)
            if let note = line.note {
                out += " <span class=\"cm\">\(inline(note))</span>"
            }
            out += "</li>"
        }
        out += "</ol>"
        if let foot = spec.foot {
            out += "<p class=\"foot\">\(inline(foot))</p>"
        }
        out += "</div>\n"
    }

    private func io(_ label: String, _ value: String) -> String {
        "<div class=\"io\"><b>\(escape(label))</b>\(inline(value))</div>"
    }

    // MARK: Table (mirrors ArticleDOM.buildTable)

    mutating func emitTable(_ spec: TableBlock) {
        let sep: String
        switch spec.separator {
        case .row: sep = "sep-row"
        case .column: sep = "sep-col"
        case .grid: sep = "sep-grid"
        case .none: sep = "sep-none"
        }
        let cols = max(1, spec.columns)
        out += "<div class=\"dtable \(sep)\" style=\"grid-template-columns:repeat(\(cols), minmax(0, 1fr))\">"
        for cell in spec.cells {
            switch cell {
            case let .math(tex):
                out += "<div class=\"dcell dcell-math\">\(escape("\\(" + tex + "\\)"))</div>"
            case let .text(text):
                out += "<div class=\"dcell\">\(text.isEmpty ? "" : inline(text))</div>"
            }
        }
        out += "</div>\n"
    }

    // MARK: Figure (mirrors ArticleDOM.buildFigure; no crossorigin — see header)

    mutating func emitFigure(_ spec: FigureBlock) {
        out += "<figure class=\"figure\"><img loading=\"lazy\""
        out += " alt=\"\(attr(spec.alt ?? spec.caption ?? ""))\" src=\"\(attr(spec.source))\">"
        if let caption = spec.caption {
            out += "<figcaption>\(inline(caption))</figcaption>"
        }
        out += "</figure>\n"
    }

    // MARK: Notation grid (mirrors ArticleDOM.buildNotation)

    mutating func emitNotation(_ rows: [NotationRow]) {
        out += "<div class=\"notation\">"
        for row in rows {
            out += "<div><dt>\(escape(row.symbol))</dt><dd>\(inline(row.definition))</dd></div>"
        }
        out += "</div>\n"
    }

    // MARK: Presentation deck (a live-deck override, else the static outline)

    mutating func emitPresentation(_ slides: [DeckSlide]) {
        let ordinal = deckOrdinal
        deckOrdinal += 1
        // A native facade supplied concrete HTML for this deck (a Metal-view slot
        // or a video embed) — drop it in and skip the static outline below.
        if let override = deckOverrides[ordinal] {
            out += override + "\n"
            return
        }
        let plural = slides.count == 1 ? "" : "s"
        out += "<div class=\"deck-static\">"
        out += "<p class=\"foot\">▷ Interactive presentation — \(slides.count) slide\(plural) "
        out += "(static outline; the live deck needs the web edition):</p>"
        for slide in slides {
            out += "<h4>\(escape(slide.title))</h4>"
            for block in slide.blocks { emitBlock(block) }
        }
        out += "</div>\n"
    }

    // MARK: Footer (mirrors ArticleDOM.renderFooter)

    mutating func emitFooter(_ lines: [String]) {
        out += "<footer class=\"foot\">"
        for (index, line) in lines.enumerated() {
            if index > 0 { out += "<br>" }
            out += inline(line)
        }
        out += "</footer>\n"
    }
}

// MARK: - Escaping + inline markup (file-private, Foundation-free)

/// HTML-escapes text content (`&`, `<`, `>`); `quotes` adds `"` for attributes.
/// TeX inside text (`\(…\)`, `$$…$$`) survives — the browser un-escapes the text
/// node before MathJax reads its `textContent`, so `p < q` in math is safe.
private func escape(_ string: String, quotes: Bool = false) -> String {
    var result = ""
    result.reserveCapacity(string.count)
    for character in string {
        switch character {
        case "&": result += "&amp;"
        case "<": result += "&lt;"
        case ">": result += "&gt;"
        case "\"" where quotes: result += "&quot;"
        default: result.append(character)
        }
    }
    return result
}

private func attr(_ string: String) -> String { escape(string, quotes: true) }

/// Renders `*italic*` / `**bold**` / `` `code` `` runs to inline HTML, escaping
/// each run's text; plain runs keep their `\(…\)` math for MathJax.
private func inline(_ text: String) -> String {
    var result = ""
    for segment in ArticleInlineParser.segments(text) {
        let escaped = escape(segment.text)
        switch segment.style {
        case .plain: result += escaped
        case .bold: result += "<strong>\(escaped)</strong>"
        case .italic: result += "<em>\(escaped)</em>"
        case .code: result += "<code>\(escaped)</code>"
        }
    }
    return result
}

/// The MathJax v3 config + CDN loader, matching `DocumentMount.ensureMathJax`
/// (manual `\tag` numbering → `tags:'none'`). Raw string: the `\\(` etc. reach
/// the file as literal `\\(`, which the browser's JS parses back to `\(`.
private let mathJaxHead = #"""
<script>
window.MathJax = {
  tex: {
    inlineMath: [['\\(','\\)'], ['$','$']],
    displayMath: [['$$','$$'], ['\\[','\\]']],
    tags: 'none', processEscapes: true
  },
  chtml: { mtextInheritFont: true },
  options: { skipHtmlTags: ['script','noscript','style','textarea','pre','code'] }
};
</script>
<script async src="https://cdn.jsdelivr.net/npm/mathjax@3/es5/tex-mml-chtml.js"></script>

"""#
