// FontRole — the author-facing *intent* of a piece of text (`Text("…", font:
// .title)`). A role is a pure value: it names a slot, not a face. The kernel's
// `FontBook` resolves a role to a concrete (Font, size) pair at scene-build
// time, and the web facade registers the loaded faces per role at mount. Pure
// and host-safe, so authoring code type-checks without any font loaded.

public enum FontRole: Sendable, Hashable, CaseIterable {
    /// Large display text — scene titles, section openers.
    case title
    /// Mid-weight headings inside a board.
    case heading
    /// Default running text (the `Text(_:)` default).
    case body
    /// Small annotations — axis labels, footnotes.
    case caption
    /// Mathematical text set in the serif face (Computer Modern).
    case math
    /// Fixed-width text — code listings, key hints.
    case mono
}
