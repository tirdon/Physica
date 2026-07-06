// TrackingTextEntity — an animated value displayed as text: `value` drives a
// `ValueTracking` formatter (integer / decimal / unicode) and every write
// reglyphs through the shared `TextEntity` layout, so the counter re-typesets
// as it counts. `count(to:)` returns an ordinary Animation (a PropertyTrack on
// `value`), scrub-safe like any other property.
//
//   let score = Counter(0, font: .title)
//   scene.add(score)
//   scene.play(score.count(to: 100), for: 2.s)

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public final class TrackingTextEntity: Entity {
    public let tracking: any ValueTracking
    public let font: Font?
    public let fontSize: Real

    /// The animated value; every write re-formats and reglyphs.
    public var value: Real {
        didSet { relayout() }
    }

    public init(
        _ initial: Real = 0,
        tracking: any ValueTracking = IntegerTracking(),
        font: Font?,
        fontSize: Real = 1,
        color: Color = .white
    ) {
        self.value = initial
        self.tracking = tracking
        self.font = font
        self.fontSize = fontSize
        super.init()
        components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color, strokeColor: color, strokeWidth: 0.012 * fontSize, isFilled: true
        )
        relayout()
    }

    private func relayout() {
        let string = tracking.text(for: value)
        var component = components[TextComponent.self] ?? TextComponent()
        component.glyphs = font.map { TextEntity.layoutGlyphs(string, font: $0) } ?? []
        component.fontSize = fontSize
        component.writeProgress = 1   // counters show; they are not written glyph-by-glyph
        components[TextComponent.self] = component
        name = string
    }

    public override var localBounds: Bounds {
        guard let component = components[TextComponent.self] else { return .empty }
        var bounds = Bounds.empty
        for glyph in component.glyphs {
            let path = glyph.path.translated(by: glyph.offset).scaled(by: component.fontSize)
            bounds = bounds.union(path.bounds)
        }
        return bounds
    }

    /// Animates the value to `target`: `scene.play(score.count(to: 100), for: 2.s)`.
    @discardableResult
    public func count(to target: Real) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: CountBlueprint(target: target)
        )])
    }
}

/// The facade spelling, mirroring `Text(_:font:)`: resolves the role through
/// `FontBook` (degrades to an empty-glyph counter with no face registered).
@MainActor
public func Counter(
    _ initial: Real = 0,
    tracking: any ValueTracking = IntegerTracking(),
    font role: FontRole = .body,
    color: Color = .white
) -> TrackingTextEntity {
    let (font, size) = FontBook.resolve(role)
    return TrackingTextEntity(
        initial, tracking: tracking, font: font, fontSize: size, color: color
    )
}

struct CountBlueprint: AnimationBlueprint {
    let target: Real
    var debugLabel: String { "count(to: \(fmt(target, decimals: 2)))" }

    func makeTrack(
        target entity: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: entity, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: entity)).\(debugLabel)",
            read: { ($0 as? TrackingTextEntity)?.value ?? 0 },
            write: { entity, value in
                (entity as? TrackingTextEntity)?.value = value
            },
            resolveEnd: { _, _ in target }
        )
    }
}
