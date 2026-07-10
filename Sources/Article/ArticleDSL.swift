// ArticleDSL — a platform-neutral document model + result-builder authoring
// surface for rendering Medium-style scientific articles into the browser DOM.
// This file has NO Foundation and NO JavaScriptKit; it is pure Swift value types,
// so `swift build` type-checks it on macOS and the model is a `Sendable` value
// layer beneath the `@MainActor` DOM renderer (the repo's concurrency split: a
// pure value graph under a MainActor object graph). It is the leaf of the
// `PhysicaArticle` target — a JSKit-free home for the document model shared by
// two consumers: the WASI DOM renderer (`ArticleDOM`, in PhysicaWeb) and the
// native static-HTML serializer (`ArticleHTML`, same target). An authored
// `Document` (e.g. Example3's HamiltonianArticle) drives either.
//
// The surface (capitalized = structural, lowercase = flow content):
//
//     Document {
//         Title(eyebrow: "…", "Headline", subtitle: "…",
//               byline: Byline(avatar: "PH", name: "Physica", meta: "…"),
//               abstract: "…", stats: [Stat(value: "1/240 s", label: "step")])
//
//         Chapter("The state you store", id: "state") {
//             "A paragraph. Inline math rides along: \\(p = m v\\)."
//             math(type: .equation, tag: "hamilton") { "\\dot q = \\partial H/\\partial p" }
//             headline("A subheading")
//             notation { Def("\\(H\\)", "the Hamiltonian") }
//             procedure(name: "Procedure 1", title: "…", input: "…", output: "…") {
//                 Step("\\(p \\gets p - \\tfrac{h}{2}\\,\\nabla U\\)", note: "half-kick")
//                 Return("updated state")
//             }
//             table(columns: 2) { formula("\\Delta t = 1/240"); "fixed step" }
//             figure("figures/rig.png", caption: "The rig, mid-swing.")
//             presentation { slide("Title") { "slide body" } }
//         }
//
//         Footer { "line one"; "line two" }
//     }
//
// Notes on the shape: math/heading bodies are TeX / text *strings* (raw
// `x + y = z` is not valid Swift), `Title` takes named metadata rather than a
// `{ }` block, table math cells use `formula("…")` (a bare string in a table is a
// text cell), and the deck's slide builder is lowercase `slide` (the capitalized
// `Slide` type is taken by PhysicaStory).
//
// A slide's body is either declarative text blocks (`slide("t") { "…" }`, fed to
// the deck's caption band — see below) or, for full author control of the
// canvas, a live-animation closure over the deck's `Scene`, exactly like
// `story.slide(title) { s in … }` in the framework itself:
//
//     presentation {
//         slide("Orbit") { scene in
//             let dot = Circle(radius: 0.2)
//             scene.play(.write(dot), for: 0.6.s)
//         }
//     }
//
// `DeckSlide.animate` is `@MainActor`, so it (and everything containing it) is
// necessarily off the main Sendable value graph in the general case; the field
// is `nonisolated(unsafe)` because in practice a `Document` is only ever built
// and consumed on the main actor (`ArticleDOM.render` is `@MainActor`), so the
// rest of the model can keep its `Sendable` conformance for documents that
// don't use this escape hatch.

import PhysicaFoundation
import PhysicaKernel

// MARK: - Leaf value types

/// A display-math block's flavour. `.equation` is auto-numbered `(1)`, `(2)`, …
/// at the trailing edge (via a MathJax `\tag`); `.display` is an unnumbered
/// centered block.
public enum MathKind: Sendable {
    case equation
    case display
}

/// The author byline shown under the title (avatar initials + name + metadata).
public struct Byline: Sendable {
    public var avatar: String
    public var name: String
    public var meta: String

    public init(avatar: String, name: String, meta: String) {
        self.avatar = avatar
        self.name = name
        self.meta = meta
    }
}

/// A stat chip (`value` in the accent serif, `label` in small-caps mono).
public struct Stat: Sendable {
    public var value: String
    public var label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

/// One line of a `procedure` float. `text` may carry inline math (`\(…\)`); a
/// `note` renders as a trailing comment; `isReturn` marks the `return` line.
public struct ProcedureLine: Sendable {
    public var text: String
    public var note: String?
    public var isReturn: Bool
}

/// A `notation` grid row: a symbol (usually inline math) and its definition.
public struct NotationRow: Sendable {
    public var symbol: String
    public var definition: String
}

/// One cell of a `table`: either an inline-math cell or a plain-text cell.
public enum TableCell: Sendable {
    case math(String)
    case text(String)
}

/// Which borders a `table` draws.
public enum TableSeparator: Sendable {
    case row
    case column
    case grid
    case none
}

/// A single slide inside a `presentation` deck (a heading + a block body, or a
/// live-animation closure — see `slide(_:_:)` below).
public struct DeckSlide: Sendable {
    public var title: String
    public var blocks: [Block]
    /// Set only by the `slide(_:_:)` animation overload; runs against the
    /// deck's live `Scene` when the story boots. See the file header.
    public nonisolated(unsafe) var animate: (@MainActor (Scene) -> Void)?
}

// MARK: - Composite block specs

public struct ProcedureBlock: Sendable {
    public var name: String
    public var title: String
    public var input: String?
    public var output: String?
    public var foot: String?
    public var lines: [ProcedureLine]
}

public struct TableBlock: Sendable {
    public var columns: Int
    public var separator: TableSeparator
    public var cells: [TableCell]
}

/// A full-column figure: a bitmap (any URL / data: URI the page can load) with
/// an optional caption. Under COEP a cross-origin source must answer with CORS
/// headers (the `<img>` is created `crossorigin`); data:/same-origin need nothing.
public struct FigureBlock: Sendable {
    public var source: String
    /// Rendered as a `<figcaption>`; may carry inline `\(…\)` math.
    public var caption: String?
    /// Screen-reader text; defaults to the caption.
    public var alt: String?
}

// MARK: - Block: flowing article content (inside chapters, slides, …)

public indirect enum Block: Sendable {
    case paragraph(String)      // may contain inline `\(…\)` math
    case headline(String)
    case subheadline(String)
    case math(MathKind, tag: String?, tex: String)
    case procedure(ProcedureBlock)
    case table(TableBlock)
    case figure(FigureBlock)
    case presentation([DeckSlide])
    case notation([NotationRow])
}

// MARK: - Section: top-level document structure

public struct TitleBlock: Sendable {
    public var eyebrow: String?
    public var headline: String
    public var subtitle: String?
    public var byline: Byline?
    public var abstract: String?
    public var stats: [Stat]
}

public struct ChapterBlock: Sendable {
    public var title: String
    public var id: String?
    public var blocks: [Block]
}

public enum Section: Sendable {
    case title(TitleBlock)
    case chapter(ChapterBlock)
    case footer([String])
}

/// A whole article, assembled from a `@DocumentBuilder` body.
public struct Document: Sendable {
    public var sections: [Section]
    /// Page title when the facade auto-mounts ("" = leave the page's own).
    public var title: String
    /// The page background theme: `.documentLight` (default, the stock warm
    /// paper) or `.documentDark` — any `Color` works, the palette derives from
    /// its luminance (`ArticleStyle.theme(background:)`).
    public var background: Color

    #if os(WASI)
    /// The WASI auto-mount hook. `PhysicaWeb.DocumentAutoMount.install()` wires
    /// this to the DOM renderer so a bare `Document("title") { … }` statement
    /// mounts itself into the page. It lives here (not a direct call) because the
    /// mount machinery — JavaScriptKit, `ArticleDOM`, MathJax — sits in a target
    /// that depends *on* this one, so the model can't name it. nil in a
    /// JSKit-free build (host / native), where the initializer just builds.
    nonisolated(unsafe) public static var autoMount: ((Document) -> Void)?
    #endif

    public init(background: Color = .documentLight, @DocumentBuilder _ content: () -> [Section]) {
        self.title = ""
        self.background = background
        self.sections = content()
    }

    /// The facade spelling: builds the document AND (on WASI, once
    /// `DocumentAutoMount.install()` has run) auto-mounts it into the page —
    /// `Document("Physics · Rigid bodies") { Title(…); Chapter(…) { … } }` as a
    /// bare statement renders the article (outline logged first, MathJax
    /// injected, `ArticleDOM` walked). On the host / native it just builds the
    /// value, so authoring code stays host-typecheckable and can be serialized to
    /// a static HTML file (`ArticleHTML`). `background: .documentDark` flips the
    /// page to the dark palette.
    @discardableResult
    public init(_ title: String, background: Color = .documentLight, @DocumentBuilder _ content: () -> [Section]) {
        self.title = title
        self.background = background
        self.sections = content()
        #if os(WASI)
        Document.autoMount?(self)
        #endif
    }
}

// MARK: - Result builders

@resultBuilder
public enum DocumentBuilder {
    public static func buildBlock(_ parts: [Section]...) -> [Section] { parts.flatMap { $0 } }
    public static func buildExpression(_ section: Section) -> [Section] { [section] }
    public static func buildOptional(_ parts: [Section]?) -> [Section] { parts ?? [] }
    public static func buildEither(first parts: [Section]) -> [Section] { parts }
    public static func buildEither(second parts: [Section]) -> [Section] { parts }
    public static func buildArray(_ parts: [[Section]]) -> [Section] { parts.flatMap { $0 } }
}

@resultBuilder
public enum BlockBuilder {
    public static func buildBlock(_ parts: [Block]...) -> [Block] { parts.flatMap { $0 } }
    public static func buildExpression(_ block: Block) -> [Block] { [block] }
    public static func buildExpression(_ text: String) -> [Block] { [.paragraph(text)] }
    public static func buildOptional(_ parts: [Block]?) -> [Block] { parts ?? [] }
    public static func buildEither(first parts: [Block]) -> [Block] { parts }
    public static func buildEither(second parts: [Block]) -> [Block] { parts }
    public static func buildArray(_ parts: [[Block]]) -> [Block] { parts.flatMap { $0 } }
}

@resultBuilder
public enum LineBuilder {
    public static func buildBlock(_ parts: [String]...) -> [String] { parts.flatMap { $0 } }
    public static func buildExpression(_ line: String) -> [String] { [line] }
    public static func buildOptional(_ parts: [String]?) -> [String] { parts ?? [] }
    public static func buildArray(_ parts: [[String]]) -> [String] { parts.flatMap { $0 } }
}

@resultBuilder
public enum ProcedureBuilder {
    public static func buildBlock(_ parts: [ProcedureLine]...) -> [ProcedureLine] { parts.flatMap { $0 } }
    public static func buildExpression(_ line: ProcedureLine) -> [ProcedureLine] { [line] }
    public static func buildOptional(_ parts: [ProcedureLine]?) -> [ProcedureLine] { parts ?? [] }
    public static func buildArray(_ parts: [[ProcedureLine]]) -> [ProcedureLine] { parts.flatMap { $0 } }
}

@resultBuilder
public enum TableBuilder {
    public static func buildBlock(_ parts: [TableCell]...) -> [TableCell] { parts.flatMap { $0 } }
    public static func buildExpression(_ cell: TableCell) -> [TableCell] { [cell] }
    public static func buildExpression(_ text: String) -> [TableCell] { [.text(text)] }
    public static func buildOptional(_ parts: [TableCell]?) -> [TableCell] { parts ?? [] }
    public static func buildArray(_ parts: [[TableCell]]) -> [TableCell] { parts.flatMap { $0 } }
}

@resultBuilder
public enum SlideBuilder {
    public static func buildBlock(_ parts: [DeckSlide]...) -> [DeckSlide] { parts.flatMap { $0 } }
    public static func buildExpression(_ slide: DeckSlide) -> [DeckSlide] { [slide] }
    public static func buildOptional(_ parts: [DeckSlide]?) -> [DeckSlide] { parts ?? [] }
    public static func buildArray(_ parts: [[DeckSlide]]) -> [DeckSlide] { parts.flatMap { $0 } }
}

@resultBuilder
public enum NotationBuilder {
    public static func buildBlock(_ parts: [NotationRow]...) -> [NotationRow] { parts.flatMap { $0 } }
    public static func buildExpression(_ row: NotationRow) -> [NotationRow] { [row] }
    public static func buildOptional(_ parts: [NotationRow]?) -> [NotationRow] { parts ?? [] }
    public static func buildArray(_ parts: [[NotationRow]]) -> [NotationRow] { parts.flatMap { $0 } }
}

// MARK: - DSL entry points (capitalized = structural, lowercase = flow content)

public func Title(
    eyebrow: String? = nil,
    _ headline: String,
    subtitle: String? = nil,
    byline: Byline? = nil,
    abstract: String? = nil,
    stats: [Stat] = []
) -> Section {
    .title(TitleBlock(
        eyebrow: eyebrow, headline: headline, subtitle: subtitle,
        byline: byline, abstract: abstract, stats: stats
    ))
}

public func Chapter(_ title: String, id: String? = nil, @BlockBuilder _ content: () -> [Block]) -> Section {
    .chapter(ChapterBlock(title: title, id: id, blocks: content()))
}

public func Footer(@LineBuilder _ content: () -> [String]) -> Section {
    .footer(content())
}

/// A paragraph. A bare `"string"` in a `@BlockBuilder` also becomes one, so `p`
/// is only needed for an explicit (or empty) paragraph.
public func p(_ text: String = "") -> Block { .paragraph(text) }

public func headline(_ text: String) -> Block { .headline(text) }
public func subheadline(_ text: String) -> Block { .subheadline(text) }

/// A display-math block. `type: .equation` is numbered at the trailing edge.
public func math(type: MathKind = .display, tag: String? = nil, _ tex: () -> String) -> Block {
    .math(type, tag: tag, tex: tex())
}

public func procedure(
    name: String,
    title: String,
    input: String? = nil,
    output: String? = nil,
    foot: String? = nil,
    @ProcedureBuilder _ lines: () -> [ProcedureLine]
) -> Block {
    .procedure(ProcedureBlock(
        name: name, title: title, input: input, output: output, foot: foot, lines: lines()
    ))
}

public func Step(_ text: String, note: String? = nil) -> ProcedureLine {
    ProcedureLine(text: text, note: note, isReturn: false)
}

public func Return(_ text: String, note: String? = nil) -> ProcedureLine {
    ProcedureLine(text: text, note: note, isReturn: true)
}

public func table(columns: Int, separator: TableSeparator = .row, @TableBuilder _ cells: () -> [TableCell]) -> Block {
    .table(TableBlock(columns: columns, separator: separator, cells: cells()))
}

/// An inline-math cell inside a `table` (a bare string is a text cell).
public func formula(_ tex: String) -> TableCell { .math(tex) }

/// A figure: a full-column image with an optional caption.
public func figure(_ source: String, caption: String? = nil, alt: String? = nil) -> Block {
    .figure(FigureBlock(source: source, caption: caption, alt: alt))
}

public func presentation(@SlideBuilder _ slides: () -> [DeckSlide]) -> Block {
    .presentation(slides())
}

/// One slide of a `presentation` deck. Lowercase to avoid the `Slide` type in
/// PhysicaStory; the deck-slide value type is `DeckSlide`. Blocks feed the
/// deck's caption band (see `ArticleStoryDeck.captionText`); the slide shows the
/// deck's default title + underline animation.
public func slide(_ title: String, @BlockBuilder _ content: () -> [Block]) -> DeckSlide {
    DeckSlide(title: title, blocks: content(), animate: nil)
}

/// One slide with full author control of the canvas: `animate` runs against the
/// deck's live `Scene` when the story boots, exactly like `story.slide(title) {
/// s in … }` in the framework itself — write/draw entities, plot a graph,
/// anything `Scene` supports. Replaces the deck's default title + underline. An
/// optional `caption` still narrates in the deck's caption band, same as blocks do.
public func slide(
    _ title: String, caption: String? = nil, _ animate: @escaping @MainActor (Scene) -> Void
) -> DeckSlide {
    DeckSlide(title: title, blocks: caption.map { [.paragraph($0)] } ?? [], animate: animate)
}

public func notation(@NotationBuilder _ rows: () -> [NotationRow]) -> Block {
    .notation(rows())
}

public func Def(_ symbol: String, _ definition: String) -> NotationRow {
    NotationRow(symbol: symbol, definition: definition)
}
