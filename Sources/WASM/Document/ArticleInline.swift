// ArticleInline — the shared inline-markup renderer. Splits a string into runs of
// `*italic*`, `**bold**`, `` `code` `` and plain text, appending each as the right
// DOM node while leaving plain runs (and their `\(…\)` inline math) as text nodes
// for MathJax to typeset. Used by both the article body (ArticleDOM) and the
// embedded story deck's caption band (ArticleStoryDeck), so the two render prose
// identically.

#if os(WASI)
import JavaScriptKit

@MainActor
enum ArticleInline {
    /// Appends `text` to `parent`, parsing markdown emphasis into styled children.
    static func append(_ text: String, to parent: JSValue, using dom: JSObject) {
        for segment in segments(text) {
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

    private enum Style { case plain, bold, italic, code }
    private struct Segment { var style: Style; var text: String }

    /// Splits a string into styled runs. Markup markers (`**`, `*`, `` ` ``) never
    /// occur inside this article's TeX, so a naive left-to-right scan is safe: an
    /// unmatched marker falls through as a literal character.
    private static func segments(_ input: String) -> [Segment] {
        let chars = Array(input)
        var out: [Segment] = []
        var buf = ""
        var i = 0

        func flush() {
            if !buf.isEmpty { out.append(Segment(style: .plain, text: buf)); buf = "" }
        }
        func findClose(from start: Int, _ delim: [Character]) -> Int? {
            var j = start
            while j + delim.count <= chars.count {
                if Array(chars[j ..< j + delim.count]) == delim { return j }
                j += 1
            }
            return nil
        }

        while i < chars.count {
            let c = chars[i]
            if c == "`" {
                if let close = findClose(from: i + 1, ["`"]) {
                    flush()
                    out.append(Segment(style: .code, text: String(chars[(i + 1) ..< close])))
                    i = close + 1
                    continue
                }
            } else if c == "*" {
                let bold = (i + 1 < chars.count && chars[i + 1] == "*")
                let delim: [Character] = bold ? ["*", "*"] : ["*"]
                let start = i + delim.count
                if let close = findClose(from: start, delim) {
                    flush()
                    out.append(Segment(style: bold ? .bold : .italic,
                                       text: String(chars[start ..< close])))
                    i = close + delim.count
                    continue
                }
            }
            buf.append(c)
            i += 1
        }
        flush()
        return out
    }
}
#endif
