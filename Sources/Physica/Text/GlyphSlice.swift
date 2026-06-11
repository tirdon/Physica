// Glyph slices — Manim-style indexing into text and formulas:
// `title[0]`, `title[1..<4]`, `formula[(formula.glyphCount - 4)...]`.
// Slices return deferred Animations like every other factory:
// `scene.play(title[0..<3].color(.orange), for: 0.5.s)`.

@MainActor
public struct GlyphSlice {
    let text: TextEntity
    /// Unclamped; blueprints clamp against the live glyph count at begin,
    /// so out-of-range slices are safe no-ops.
    let range: Range<Int>

    /// Animates the slice's glyph colors toward `value` (fill and stroke).
    /// Rewinding restores the previous overrides exactly — including "none".
    @discardableResult
    public func color(_ value: Color) -> Animation {
        color(mix: [value])
    }

    /// Gradient across the slice: each glyph heads for its sample of the
    /// multi-stop ramp, first stop at the slice's first glyph, last at its
    /// last — `title.color(mix: [.blue, .teal, .purple])`.
    @discardableResult
    public func color(mix colors: [Color]) -> Animation {
        Animation(pairs: [
            AnimationPair(target: text, blueprint: GlyphColorBlueprint(range: range, colors: colors))
        ])
    }

    /// Animates the slice's per-glyph opacity factor.
    @discardableResult
    public func fade(to opacity: Real) -> Animation {
        Animation(pairs: [
            AnimationPair(target: text, blueprint: GlyphFadeBlueprint(range: range, opacity: opacity))
        ])
    }

    @discardableResult
    public func opacity(_ value: Real) -> Animation {
        fade(to: value)
    }
}

@MainActor
public extension TextEntity {
    var glyphCount: Int { textComponent.glyphs.count }

    /// Whole-text gradient (per glyph; entity-level `color(_:)` recolors the
    /// shared style instead).
    @discardableResult
    func color(mix colors: [Color]) -> Animation {
        self[0...].color(mix: colors)
    }

    subscript(index: Int) -> GlyphSlice {
        GlyphSlice(text: self, range: index..<(index + 1))
    }

    subscript(range: Range<Int>) -> GlyphSlice {
        GlyphSlice(text: self, range: range)
    }

    subscript(range: ClosedRange<Int>) -> GlyphSlice {
        GlyphSlice(text: self, range: range.lowerBound..<(range.upperBound + 1))
    }

    subscript(range: PartialRangeFrom<Int>) -> GlyphSlice {
        GlyphSlice(text: self, range: range.lowerBound..<Int.max)
    }
}

// MARK: - Blueprints

/// Both blueprints drive a 0→1 progress value; per-glyph start state is
/// captured once in `read` (PropertyTrack.begin is idempotent), and a t = 0
/// write restores it verbatim — that is what makes scrubbing exact.

struct GlyphColorBlueprint: AnimationBlueprint {
    let range: Range<Int>
    /// One color = uniform; several = a ramp sampled across the slice.
    let colors: [Color]

    var debugLabel: String {
        let suffix = colors.count == 1
            ? colors[0].debugDescription
            : "mix: \(colors.count)"
        return "glyphs[\(range.lowerBound)..<\(range.upperBound)].color(\(suffix))"
    }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        var starts: [Color?]?
        return PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { entity in
                if starts == nil, let component = entity.components[TextComponent.self] {
                    let indices = range.clamped(to: 0..<component.glyphs.count)
                    starts = indices.map { component.glyphs[$0].color }
                }
                return 0
            },
            write: { entity, value in
                guard !colors.isEmpty,
                    var component = entity.components[TextComponent.self]
                else { return }
                let indices = range.clamped(to: 0..<component.glyphs.count)
                let base = entity.components[RenderStyleComponent.self]?.color ?? .white
                for index in indices {
                    let position = index - indices.lowerBound
                    let start = starts.map { $0[position] } ?? nil
                    let target = Self.ramp(
                        colors, at: Real(position) / Real(Swift.max(indices.count - 1, 1))
                    )
                    if value <= 0 {
                        component.glyphs[index].color = start
                    } else if value >= 1 {
                        component.glyphs[index].color = target
                    } else {
                        component.glyphs[index].color = Color.lerp(start ?? base, target, value)
                    }
                }
                entity.components[TextComponent.self] = component
            },
            resolveEnd: { _, _ in 1 }
        )
    }

    /// Sample a multi-stop color ramp at t ∈ [0, 1]. Exact at the stops —
    /// `lerp(a, b, 1)` carries float residue, so snap instead.
    static func ramp(_ colors: [Color], at t: Real) -> Color {
        guard colors.count > 1 else { return colors[0] }
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Real(colors.count - 1)
        let index = Swift.min(Int(scaled.rounded(.down)), colors.count - 2)
        let fraction = scaled - Real(index)
        if fraction <= 0 { return colors[index] }
        if fraction >= 1 { return colors[index + 1] }
        return Color.lerp(colors[index], colors[index + 1], fraction)
    }
}

struct GlyphFadeBlueprint: AnimationBlueprint {
    let range: Range<Int>
    let opacity: Real

    var debugLabel: String {
        "glyphs[\(range.lowerBound)..<\(range.upperBound)].fade(to: \(fmt(opacity, decimals: 2)))"
    }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        var starts: [Real]?
        return PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { entity in
                if starts == nil, let component = entity.components[TextComponent.self] {
                    let indices = range.clamped(to: 0..<component.glyphs.count)
                    starts = indices.map { component.glyphs[$0].opacity }
                }
                return 0
            },
            write: { entity, value in
                guard var component = entity.components[TextComponent.self] else { return }
                let indices = range.clamped(to: 0..<component.glyphs.count)
                for index in indices {
                    let start = starts.map { $0[index - indices.lowerBound] } ?? 1
                    component.glyphs[index].opacity =
                        value >= 1 ? opacity : Real.lerp(start, opacity, value)
                }
                entity.components[TextComponent.self] = component
            },
            resolveEnd: { _, _ in 1 }
        )
    }
}
