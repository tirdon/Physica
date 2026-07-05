// ArticleOutline — a platform-neutral, plain-text dump of a `Document`.
//
// This is the "log the structure first" companion to the DOM renderer: an author
// entry point can print it BEFORE touching the DOM, so a GPU-free / no-DOM smoke
// run under Bun (which has no `document` to render into) still produces
// meaningful output and exits cleanly — the same philosophy WebRuntime uses when
// it logs the timeline before booting the renderer.
//
// Pure: it only builds `[String]` lines from the value model, so it is trivially
// testable and shared by both the WASI and host `@main` paths of a consumer.

public enum ArticleOutline {
    /// Renders the document to plain-text lines (no I/O). `banner` is the first
    /// line — a consumer can pass its own label (e.g. the demo name) so the
    /// framework outline stays product-agnostic.
    public static func lines(for document: Document, banner: String = "Article outline") -> [String] {
        var out: [String] = [banner]
        var chapterNo = 0
        var equationNo = 0

        for section in document.sections {
            switch section {
            case let .title(title):
                out.append("Title: \(title.headline)")
                if let eyebrow = title.eyebrow { out.append("  eyebrow: \(eyebrow)") }
                if let subtitle = title.subtitle { out.append("  subtitle: \(subtitle)") }
                if let byline = title.byline { out.append("  byline: \(byline.name) — \(byline.meta)") }
                if title.abstract != nil { out.append("  abstract: (present)") }
                if !title.stats.isEmpty {
                    out.append("  stats: " + title.stats.map { "\($0.value) \($0.label)" }.joined(separator: ", "))
                }

            case let .chapter(chapter):
                chapterNo += 1
                out.append("§\(chapterNo) Chapter: \(chapter.title)")
                for block in chapter.blocks {
                    appendBlock(block, indent: "  - ", into: &out, equationNo: &equationNo)
                }

            case let .footer(lines):
                out.append("Footer (\(lines.count) line\(lines.count == 1 ? "" : "s"))")
            }
        }
        return out
    }

    private static func appendBlock(
        _ block: Block, indent: String, into out: inout [String], equationNo: inout Int
    ) {
        switch block {
        case let .paragraph(text):
            out.append(indent + "paragraph" + (text.isEmpty ? " (empty)" : ": " + snippet(text)))
        case let .headline(text):
            out.append(indent + "headline: " + text)
        case let .subheadline(text):
            out.append(indent + "subheadline: " + text)
        case let .math(kind, tag, tex):
            var label = "math(\(kind == .equation ? "equation" : "display"))"
            if kind == .equation {
                equationNo += 1
                label += " (\(equationNo))"
            }
            if let tag { label += " tag=\(tag)" }
            out.append(indent + label + ": " + snippet(tex))
        case let .procedure(spec):
            out.append(indent + "procedure: \(spec.name) — \(spec.title) [\(spec.lines.count) lines]")
        case let .table(spec):
            let rows = spec.columns > 0 ? (spec.cells.count + spec.columns - 1) / spec.columns : 0
            out.append(indent + "table: \(spec.columns) cols × \(rows) rows (\(spec.cells.count) cells)")
        case let .presentation(slides):
            out.append(indent + "presentation: \(slides.count) slides")
            for slide in slides {
                let suffix = slide.animate != nil ? " (animated)" : ""
                out.append(indent + "  slide: " + slide.title + suffix)
            }
        case let .notation(rows):
            out.append(indent + "notation: \(rows.count) rows")
        }
    }

    private static func snippet(_ text: String, max: Int = 60) -> String {
        let flat = text.split(whereSeparator: { $0 == "\n" }).joined(separator: " ")
        if flat.count <= max { return flat }
        return String(flat.prefix(max)) + "…"
    }
}
