// ArticleInlineParser — the platform-neutral half of inline markup: it splits a
// string into runs of `*italic*`, `**bold**`, `` `code` `` and plain text, and
// nothing more (no DOM, no strings-to-HTML). Both consumers build the actual
// output from these runs: `ArticleInline` (PhysicaWeb) appends DOM nodes, and
// `ArticleHTML` (this target) emits escaped HTML. Plain runs keep their `\(…\)`
// inline math verbatim for MathJax to typeset downstream.

public enum ArticleInlineParser {
    public enum Style: Sendable { case plain, bold, italic, code }
    public struct Segment: Sendable {
        public var style: Style
        public var text: String
    }

    /// Splits a string into styled runs. Markup markers (`**`, `*`, `` ` ``) never
    /// occur inside this article's TeX, so a naive left-to-right scan is safe: an
    /// unmatched marker falls through as a literal character.
    public static func segments(_ input: String) -> [Segment] {
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
                // In-place compare — delim is 1–2 chars, so avoid allocating a
                // subarray slice at every scan position (O(n) allocs → 0).
                if chars[j] == delim[0], delim.count == 1 || chars[j + 1] == delim[1] { return j }
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
