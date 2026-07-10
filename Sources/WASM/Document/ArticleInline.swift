// ArticleInline — the DOM half of inline markup. The run-splitting logic is
// shared (`ArticleInlineParser`, PhysicaArticle); this appends each run as the
// right DOM node, leaving plain runs (and their `\(…\)` inline math) as text
// nodes for MathJax to typeset. Used by both the article body (ArticleDOM) and
// the embedded story deck's caption band (ArticleStoryDeck), so the two render
// prose identically — and identically to the static `ArticleHTML` serializer,
// which walks the same parser.

import PhysicaArticle

#if os(WASI)
import JavaScriptKit

@MainActor
enum ArticleInline {
    /// Appends `text` to `parent`, parsing markdown emphasis into styled children.
    static func append(_ text: String, to parent: JSValue, using dom: JSObject) {
        for segment in ArticleInlineParser.segments(text) {
            switch segment.style {
            case .plain:
                if !segment.text.isEmpty {
                    _ = parent.appendChild(dom.createTextNode!(segment.text))
                }
            case .bold:
                let e = dom.createElement!("strong"); e.textContent = .string(segment.text)
                _ = parent.appendChild(e)
            case .italic:
                let e = dom.createElement!("em"); e.textContent = .string(segment.text)
                _ = parent.appendChild(e)
            case .code:
                let e = dom.createElement!("code"); e.textContent = .string(segment.text)
                _ = parent.appendChild(e)
            }
        }
    }
}
#endif
