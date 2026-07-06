// TextEntity + the Write animation (stroke draws to 85% of progress, then fill
// fades in; glyphs stagger by lagRatio — the StoryboardWASM recipe, GPU-agnostic).

import PhysicaFoundation
import PhysicaTypesetting

public struct TextComponent: Component {
    /// The per-glyph unit is the parsers' shared output type in
    /// PhysicaTypesetting; the nested spelling stays for source compatibility.
    public typealias PositionedGlyph = PhysicaTypesetting.PositionedGlyph

    public var glyphs: [PositionedGlyph]
    public var fontSize: Real
    /// Whole-text Write progress (0 hidden … 1 complete).
    public var writeProgress: Real
    /// Per-glyph stagger: fraction of one glyph's window before the next starts.
    public var lagRatio: Real

    public init(
        glyphs: [PositionedGlyph] = [],
        fontSize: Real = 1,
        writeProgress: Real = 0,
        lagRatio: Real = 0.5
    ) {
        self.glyphs = glyphs
        self.fontSize = fontSize
        self.writeProgress = writeProgress
        self.lagRatio = lagRatio
    }

    public var debugString: String {
        "text(glyphs: \(glyphs.count), progress: \(fmt(writeProgress, decimals: 2)))"
    }

    /// Per-glyph stroke/fill factors for a given whole-text progress.
    /// Stroke reveals over the first 85% of a glyph's window, fill fades over the rest.
    static func glyphFactors(
        writeProgress: Real, index: Int, count: Int, lagRatio: Real
    ) -> (stroke: Real, fill: Real) {
        guard count > 0 else { return (0, 0) }
        let progress = min(max(writeProgress, 0), 1)
        // Each glyph's window length d with stagger L·d between starts:
        // total = d + (count-1)·L·d = 1.
        let window = 1 / (1 + lagRatio * Real(count - 1))
        let start = Real(index) * lagRatio * window
        let local = min(max((progress - start) / window, 0), 1)

        let stroke = min(local / 0.85, 1)
        let fillT = max((local - 0.85) / 0.15, 0)
        let fill = Easing.easeOut.apply(fillT)
        return (stroke, fill)
    }
}

@MainActor
public final class TextEntity: Entity {
    public let text: String

    public var textComponent: TextComponent {
        get { components[TextComponent.self] ?? TextComponent() }
        set { components[TextComponent.self] = newValue }
    }

    /// Lays out `text` left-to-right and centers it on the origin.
    public init(_ text: String, font: Font, fontSize: Real = 1, color: Color = .white) {
        self.text = text
        super.init()

        components[TextComponent.self] = TextComponent(
            glyphs: Self.layoutGlyphs(text, font: font), fontSize: fontSize
        )
        components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color,
            strokeColor: color,
            strokeWidth: 0.012 * fontSize,
            isFilled: true
        )
        name = text
    }

    /// The shared glyph layout (also reglyphs `TrackingTextEntity` per frame):
    /// glyphs laid out line by line (newlines break a line), each line centred
    /// by its own width, the stack centred vertically.
    static func layoutGlyphs(_ text: String, font: Font) -> [TextComponent.PositionedGlyph] {
        let spaceAdvance = font.glyph(for: " ")?.advance ?? 0.3
        let lineHeight: Real = 1.2

        var glyphs: [TextComponent.PositionedGlyph] = []
        var lines: [(start: Int, end: Int, width: Real)] = []
        var pen: Real = 0
        var penY: Real = 0
        var lineStart = 0
        func closeLine() {
            lines.append((lineStart, glyphs.count, pen))
            lineStart = glyphs.count
            pen = 0
            penY -= lineHeight
        }
        for character in text.unicodeScalars {
            if character == "\n" { closeLine(); continue }
            if character == " " { pen += spaceAdvance; continue }
            guard let glyph = font.glyph(for: character) else {
                pen += 0.5
                continue
            }
            if !glyph.path.isEmpty {
                glyphs.append(TextComponent.PositionedGlyph(path: glyph.path, offset: SIMD2(pen, penY)))
            }
            pen += glyph.advance
        }
        closeLine()

        // Centre the block: each line by its own width (centred text), the stack
        // vertically. Single-line text reduces to the original (-w/2, -0.35) shift.
        let centerY = Real(Swift.max(lines.count - 1, 0)) * lineHeight / 2 - 0.35
        for line in lines {
            let dx = -line.width / 2
            for index in line.start..<line.end {
                glyphs[index].offset.x += dx
                glyphs[index].offset.y += centerY
            }
        }
        return glyphs
    }

    /// Test/internal hook: inject pre-built glyphs without a font file.
    package init(glyphs: [TextComponent.PositionedGlyph], fontSize: Real = 1) {
        self.text = ""
        super.init()
        components[TextComponent.self] = TextComponent(glyphs: glyphs, fontSize: fontSize)
        components[RenderStyleComponent.self] = RenderStyleComponent(
            color: .white, strokeColor: .white, strokeWidth: 0.012, isFilled: true
        )
    }

    /// Shows the text immediately (for static labels that are never written).
    @discardableResult
    public func shown() -> Self {
        var component = textComponent
        component.writeProgress = 1
        textComponent = component
        return self
    }

    public override var localBounds: Bounds {
        let component = textComponent
        var bounds = Bounds.empty
        for glyph in component.glyphs {
            let path = glyph.path.translated(by: glyph.offset).scaled(by: component.fontSize)
            bounds = bounds.union(path.bounds)
        }
        return bounds
    }
}

public extension Animation {
    /// Stroke-then-fill text reveal: `scene.play(.write(title))`. Adds the entity
    /// to the scene if no earlier clip did — no `scene.add` needed first.
    /// 1 s by default (the standard blueprint default); pass `for:` to stretch.
    static func write(_ text: TextEntity) -> Animation {
        var animation = Animation(pairs: [AnimationPair(target: text, blueprint: WriteBlueprint())])
        animation.easing = .linear
        return animation
    }

    /// Backward Write: fill fades, strokes retract, last glyph first. The entity
    /// leaves the scene when the clip completes (scrubbing back restores it).
    static func erase(_ text: TextEntity) -> Animation {
        var animation = Animation(
            pairs: [AnimationPair(target: text, blueprint: WriteBlueprint(reversed: true))]
        )
        animation.easing = .linear
        return animation
    }
}

struct WriteBlueprint: AnimationBlueprint {
    /// erase(): same progress mapping run 1 → 0, target removed at the end.
    var reversed = false

    var debugLabel: String { reversed ? "erase()" : "write()" }
    var introducesTarget: Bool { !reversed }
    var removesTargetAtEnd: Bool { reversed }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { _ in reversed ? 1 : 0 },  // write starts hidden, erase starts shown
            write: { entity, value in
                guard var component = entity.components[TextComponent.self] else { return }
                component.writeProgress = value
                entity.components[TextComponent.self] = component
            },
            resolveEnd: { _, _ in reversed ? 0 : 1 }
        )
    }
}
