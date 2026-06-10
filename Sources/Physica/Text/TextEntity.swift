// TextEntity + the Write animation (stroke draws to 85% of progress, then fill
// fades in; glyphs stagger by lagRatio — the StoryboardWASM recipe, GPU-agnostic).

public struct TextComponent: Component {
    public struct PositionedGlyph: Sendable {
        /// Outline in em units.
        public var path: Path
        /// Layout offset in em units (pen position).
        public var offset: SIMD2<Real>
    }

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
    public static func glyphFactors(
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

        var glyphs: [TextComponent.PositionedGlyph] = []
        var pen: Real = 0
        for character in text.unicodeScalars {
            if character == " " {
                pen += (font.glyph(for: " ")?.advance ?? 0.3)
                continue
            }
            guard let glyph = font.glyph(for: character) else {
                pen += 0.5
                continue
            }
            if !glyph.path.isEmpty {
                glyphs.append(TextComponent.PositionedGlyph(path: glyph.path, offset: SIMD2(pen, 0)))
            }
            pen += glyph.advance
        }
        // Center: shift by half the advance width, half the cap height.
        let centerOffset = SIMD2<Real>(-pen / 2, -0.35)
        for index in glyphs.indices {
            glyphs[index].offset += centerOffset
        }

        components[TextComponent.self] = TextComponent(glyphs: glyphs, fontSize: fontSize)
        components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color,
            strokeColor: color,
            strokeWidth: 0.012 * fontSize,
            isFilled: true
        )
        name = text
    }

    /// Test/internal hook: inject pre-built glyphs without a font file.
    init(glyphs: [TextComponent.PositionedGlyph], fontSize: Real = 1) {
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

    /// Stroke-then-fill reveal. Duration scales with glyph count unless overridden.
    @discardableResult
    public func write() -> Animation {
        var animation = Animation(pairs: [(self, WriteBlueprint())])
        animation.duration = .interval(
            min(0.6 + 0.35 * TimeInterval(textComponent.glyphs.count), 6)
        )
        animation.easing = .linear
        return animation
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

struct WriteBlueprint: AnimationBlueprint {
    var defaultDuration: Duration { .seconds(2) }
    var debugLabel: String { "write()" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).write()",
            read: { _ in 0 },  // writing always starts from hidden
            write: { entity, value in
                guard var component = entity.components[TextComponent.self] else { return }
                component.writeProgress = value
                entity.components[TextComponent.self] = component
            },
            resolveEnd: { _, _ in 1 }
        )
    }
}
