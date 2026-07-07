// StoryDocument — the serializable source of truth for the editor.
//
// The Physica `Timeline` is append-only (no remove/replace/reorder), so the
// editor never mutates a live `Story`. Instead it edits this value tree and the
// `StoryCompiler` rebuilds a fresh `Story` from it on every change. Keeping the
// document a plain value type (no Physica `@MainActor` graph) makes it cheap to
// snapshot for undo/redo and trivial to serialize (Phase 3).
//
// Platform-neutral on purpose: it imports only the dependency-free core (for the
// `Real`/`Color` value types), so the host build type-checks it and the unit
// tests exercise it without a GPU or DOM. The schema starts minimal and grows
// additively per phase.

import Physica

/// A whole authored story: an ordered list of slides plus a monotonic id source
/// for minting stable element ids (mirrors Physica's `Entity.id` counter — no
/// UUID/Foundation).
struct StoryDocument: Sendable, Equatable, Codable {
    var slides: [SlideDoc]
    var nextElementID: Int
    var nextStepID: Int

    init(slides: [SlideDoc] = [], nextElementID: Int = 1, nextStepID: Int = 1) {
        self.slides = slides
        self.nextElementID = nextElementID
        self.nextStepID = nextStepID
    }

    /// A fresh document seeded with one slide and two elements, so a freshly
    /// opened editor already shows something on the stage.
    static func starter() -> StoryDocument {
        var slide = SlideDoc(title: "Slide 1", caption: "A circle and a title — your first elements.")
        slide.elements = [
            ElementDoc(id: 1, name: "Circle",
                       kind: .circle(radius: 1.2),
                       position: Vec2(-2.6, 0.1), colorHex: 0x5CD0B3),
            ElementDoc(id: 2, name: "Title",
                       kind: .text("Story Studio", fontSize: 0.9),
                       position: Vec2(1.0, 0.1), colorHex: 0xF2F2EC),
        ]
        return StoryDocument(slides: [slide], nextElementID: 3)
    }
}

/// One slide: a title, an opening narration caption, and its elements (animation
/// steps arrive in Phase 7).
struct SlideDoc: Sendable, Equatable, Codable {
    var title: String
    var caption: String
    var transition: TransitionSpec
    var elements: [ElementDoc]
    var steps: [StepDoc]

    init(title: String, caption: String = "", transition: TransitionSpec = .none,
         elements: [ElementDoc] = [], steps: [StepDoc] = []) {
        self.title = title
        self.caption = caption
        self.transition = transition
        self.elements = elements
        self.steps = steps
    }
}

/// One animation step on a slide: a verb applied to an element over [start, start+duration].
struct StepDoc: Sendable, Equatable, Codable, Identifiable {
    var id: Int
    var elementID: Int
    var verb: VerbSpec
    // Seconds, kept as explicit `Double` (Physica typealiases `TimeInterval` to
    // `Real`/`Float` on wasm — using `Double` keeps timing platform-consistent
    // and serializable, and avoids Float/Double mixing in the editor).
    var start: Double
    var duration: Double

    init(id: Int, elementID: Int, verb: VerbSpec, start: Double, duration: Double) {
        self.id = id
        self.elementID = elementID
        self.verb = verb
        self.start = start
        self.duration = duration
    }
}

/// What a step does. The compiler maps each to a Physica `Animation`.
enum VerbSpec: Sendable, Equatable, Codable {
    case write              // reveal: `.write` for text, `.draw` for shapes
    case fade(to: Real)
    case scaleTo(Real)
    case color(hex: UInt32)
    case wait               // a pure time gap

    var kind: VerbKind {
        switch self {
        case .write: return .write
        case .fade: return .fade
        case .scaleTo: return .scale
        case .color: return .color
        case .wait: return .wait
        }
    }

    /// Short label for the timeline block.
    var label: String {
        switch self {
        case .write: return "write"
        case let .fade(to): return "fade \(shortNumber(Double(to)))"
        case let .scaleTo(f): return "scale \(shortNumber(Double(f)))"
        case .color: return "color"
        case .wait: return "wait"
        }
    }

    static func makeDefault(_ kind: VerbKind) -> VerbSpec {
        switch kind {
        case .write: return .write
        case .fade: return .fade(to: 0)
        case .scale: return .scaleTo(1.4)
        case .color: return .color(hex: 0x53F0FF)
        case .wait: return .wait
        }
    }
}

/// The verb choices offered in the step editor's dropdown.
enum VerbKind: String, Sendable, CaseIterable {
    case write, fade, scale, color, wait

    var label: String {
        switch self {
        case .write: return "Write / Draw"
        case .fade: return "Fade"
        case .scale: return "Scale"
        case .color: return "Color"
        case .wait: return "Wait"
        }
    }
}

private func shortNumber(_ v: Double) -> String {
    let rounded = (v * 100).rounded() / 100
    return String(rounded)
}

/// A slide's entrance transition. Pure data (string-backed for stable JSON); the
/// compiler maps it to a Physica `SlideTransition`.
enum TransitionSpec: String, Sendable, Equatable, Codable, CaseIterable {
    case none, fade, pushLeft, pushRight, pushUp, pushDown, zoom, morph

    var label: String {
        switch self {
        case .none: return "None"
        case .fade: return "Fade"
        case .pushLeft: return "Push \u{2190}"
        case .pushRight: return "Push \u{2192}"
        case .pushUp: return "Push \u{2191}"
        case .pushDown: return "Push \u{2193}"
        case .zoom: return "Zoom"
        case .morph: return "Morph"
        }
    }
}

/// One placed element. `id` is stable across recompiles, so the compiler's
/// `id → Entity` map lets the editor re-find the live entity after a rebuild.
/// Transform/style are minimal here (position + fill colour) and grow into full
/// `TransformSpec`/`StyleSpec` in Phase 5.
struct ElementDoc: Sendable, Equatable, Identifiable, Codable {
    var id: Int
    var name: String
    var kind: ElementKind
    var position: Vec2
    var colorHex: UInt32

    init(id: Int, name: String, kind: ElementKind, position: Vec2, colorHex: UInt32) {
        self.id = id
        self.name = name
        self.kind = kind
        self.position = position
        self.colorHex = colorHex
    }
}

/// What an element *is*. Additive — `.line/.arrow/.plane` can follow.
enum ElementKind: Sendable, Equatable, Codable {
    case text(String, fontSize: Real)
    case math(tex: String, fontSize: Real)   // rendered via MathJax (web) → SVG → glyphs
    case circle(radius: Real)
    case rectangle(width: Real, height: Real)
    case triangle(side: Real)
    case image(source: String, width: Real)  // bitmap box (URL / data: URI), square

    /// The inline-editable text for this kind — the visible string for `.text`,
    /// the TeX source for `.math`, the source URL for `.image`, `nil` for shapes
    /// (nothing to type). Drives both the inspector's text field and the canvas
    /// double-click editor.
    var editableText: String? {
        switch self {
        case let .text(string, _): return string
        case let .math(tex, _): return tex
        case let .image(source, _): return source
        default: return nil
        }
    }

    /// A copy with the editable text replaced, font size/width preserved; shapes
    /// are returned unchanged. The non-mutating counterpart of `editableText`.
    func withEditableText(_ value: String) -> ElementKind {
        switch self {
        case let .text(_, fontSize): return .text(value, fontSize: fontSize)
        case let .math(_, fontSize): return .math(tex: value, fontSize: fontSize)
        case let .image(_, width): return .image(source: value, width: width)
        default: return self
        }
    }
}

/// A 2-D point in scene/world units (z is always 0 for placed elements).
struct Vec2: Sendable, Equatable, Codable {
    var x: Real
    var y: Real
    init(_ x: Real, _ y: Real) {
        self.x = x
        self.y = y
    }
}
