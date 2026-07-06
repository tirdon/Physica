// BarChart — a standalone bar chart: a `Group` of `Bar` children (one filled
// rect per datum, baseline at the chart's origin) plus optional `ErrorBar`
// whiskers. Every mutation is an Animation, scrub-safe by the track contract:
//   chart.set(newData)      — values (and errors) morph in place
//   chart.add(datum)        — a new bar grows in from the baseline
//   chart.remove(at: i)     — the bar shrinks away and the row closes the gap
// Layout: bar i sits at x = i·(barWidth + gap); value → height via valueScale.

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

/// One bar's authored datum.
public struct BarDatum: Sendable {
    public var label: String
    public var value: Real
    /// Symmetric ± error; nil = no whisker.
    public var error: Real?

    public init(_ label: String = "", _ value: Real, error: Real? = nil) {
        self.label = label
        self.value = value
        self.error = error
    }

    static func lerp(_ a: BarDatum, _ b: BarDatum, _ t: Real) -> BarDatum {
        var result = t < 1 ? a : b
        result.value = Real.lerp(a.value, b.value, t)
        if a.error == nil && b.error == nil {
            result.error = nil
        } else {
            result.error = Real.lerp(a.error ?? 0, b.error ?? 0, t)
        }
        return result
    }
}

/// One bar: a filled rect anchored at the baseline, plus its whisker.
@MainActor
public final class Bar: PathEntity {
    public internal(set) var datum: BarDatum
    let barWidth: Real
    let valueScale: Real
    /// The whisker rides as a chart sibling so its stroke isn't tied to the
    /// bar's fill style; the bar owns it (strong — before the chart attaches
    /// the whisker as a child, this is its only reference) and repositions it.
    var errorBar: ErrorBar?

    init(datum: BarDatum, width: Real, valueScale: Real, color: Color) {
        self.datum = datum
        self.barWidth = width
        self.valueScale = valueScale
        super.init(
            path: Path(),
            style: RenderStyleComponent(color: color, isFilled: true)
        )
        name = datum.label.isEmpty ? "bar" : datum.label
    }

    /// Applies a datum: rect from the baseline to value·scale (negative values
    /// hang below), whisker centered on the bar's tip.
    func apply(_ datum: BarDatum) {
        self.datum = datum
        let height = datum.value * valueScale
        if Swift.abs(height) > 1e-9 {
            path = .rect(width: barWidth, height: Swift.abs(height), center: SIMD2(0, height / 2))
        } else {
            path = Path()
        }
        refreshErrorBar()
    }

    /// Repositions the whisker after the bar's value or x-slot changed.
    func refreshErrorBar() {
        guard let errorBar else { return }
        errorBar.position = Position(position.x, datum.value * valueScale, 0)
        errorBar.halfExtent = (datum.error ?? 0) * valueScale
    }
}

@MainActor
public final class BarChart: Group {
    public let barWidth: Real
    public let gap: Real
    /// World units per value unit.
    public let valueScale: Real
    public let color: Color
    public let errorColor: Color
    public private(set) var bars: [Bar] = []

    /// The live data, read from the bars (mid-animation included).
    public var data: [BarDatum] { bars.map(\.datum) }

    public init(
        data: [BarDatum],
        barWidth: Real = 0.6,
        gap: Real = 0.3,
        valueScale: Real = 1,
        color: Color = .teal,
        errorColor: Color = .white
    ) {
        self.barWidth = barWidth
        self.gap = gap
        self.valueScale = valueScale
        self.color = color
        self.errorColor = errorColor
        super.init()
        name = "barChart"
        for datum in data {
            let bar = makeBar(datum)
            attachBar(bar, at: bars.count)
            bar.apply(datum)
        }
    }

    var slotStride: Real { barWidth + gap }
    func slotX(_ index: Int) -> Real { Real(index) * slotStride }

    /// Builds a bar (and its whisker when the datum carries an error) without
    /// attaching it — insert tracks attach/detach in apply/rewind.
    func makeBar(_ datum: BarDatum) -> Bar {
        let bar = Bar(datum: datum, width: barWidth, valueScale: valueScale, color: color)
        if datum.error != nil {
            let whisker = ErrorBar(halfExtent: 0, capWidth: barWidth * 0.6, color: errorColor)
            bar.errorBar = whisker
        }
        return bar
    }

    func attachBar(_ bar: Bar, at index: Int) {
        guard !bars.contains(where: { $0 === bar }) else { return }
        let slot = Swift.min(index, bars.count)
        insertChild(bar, at: slot)
        if let whisker = bar.errorBar {
            addChild(whisker)   // whiskers draw over every bar; order among them is free
        }
        bars.insert(bar, at: slot)
        bar.position = Position(slotX(slot), 0, 0)
        bar.refreshErrorBar()
    }

    func detachBar(_ bar: Bar) {
        removeChild(bar)
        if let whisker = bar.errorBar {
            removeChild(whisker)
        }
        bars.removeAll { $0 === bar }
    }

    /// Applies values index-paired onto the live bars (extra entries ignored).
    func applyData(_ data: [BarDatum]) {
        for (index, bar) in bars.enumerated() where index < data.count {
            bar.apply(data[index])
        }
    }

    // MARK: Animations

    /// Morphs the chart to `newData` — values and errors lerp in place
    /// (index-paired; counts should match, extra entries snap at the end).
    @discardableResult
    public func set(_ newData: [BarDatum]) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: BarDataBlueprint(data: newData)
        )])
    }

    /// Appends a bar that grows in from the baseline.
    @discardableResult
    public func add(_ datum: BarDatum) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: BarInsertBlueprint(datum: datum)
        )])
    }

    /// Shrinks the bar at `index` away; the bars after it close the gap.
    @discardableResult
    public func remove(at index: Int) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: BarRemoveBlueprint(index: index)
        )])
    }
}

// MARK: - Blueprints

struct BarDataBlueprint: AnimationBlueprint {
    let data: [BarDatum]
    var debugLabel: String { "set(bars)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        BarDataTrack(
            entity: target, to: data, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

struct BarInsertBlueprint: AnimationBlueprint {
    let datum: BarDatum
    var debugLabel: String { "add(bar)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        BarInsertTrack(
            entity: target, datum: datum, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

struct BarRemoveBlueprint: AnimationBlueprint {
    let index: Int
    var debugLabel: String { "remove(bar)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        BarRemoveTrack(
            entity: target, index: index, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

// MARK: - Tracks

/// Lerps every bar's datum from its begin-captured value to the target.
@MainActor
final class BarDataTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [BarDatum]
    private var from: [BarDatum]?

    init(
        entity: Entity, to: [BarDatum], duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.to = to
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard from == nil, let chart = entity as? BarChart else { return }
        from = chart.data
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let chart = entity as? BarChart, let from else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 { chart.applyData(from); return }
        if t >= 1 { chart.applyData(to); return }
        let count = Swift.min(from.count, to.count)
        chart.applyData((0..<count).map { BarDatum.lerp(from[$0], to[$0], t) })
    }

    func rewind(in scene: Scene) {
        if let from, let chart = entity as? BarChart {
            chart.applyData(from)
        }
    }
}

/// Appends a bar that grows in: built once at `begin`, attached whenever the
/// clip is active, removed again on rewind (the write/erase pattern for a
/// group child instead of a scene root).
@MainActor
final class BarInsertTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let datum: BarDatum
    private var bar: Bar?
    private var index = 0

    init(
        entity: Entity, datum: BarDatum, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.datum = datum
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard bar == nil, let chart = entity as? BarChart else { return }
        bar = chart.makeBar(datum)
        index = chart.bars.count
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let chart = entity as? BarChart, let bar else { return }
        if !chart.bars.contains(where: { $0 === bar }) {
            chart.attachBar(bar, at: index)
        }
        let t = progress(at: clipTime, easing: easing)
        bar.apply(BarDatum.lerp(BarDatum(datum.label, 0, error: datum.error.map { _ in 0 }), datum, t))
    }

    func rewind(in scene: Scene) {
        guard let chart = entity as? BarChart, let bar else { return }
        chart.detachBar(bar)
    }
}

/// Shrinks the bar at `index` away while the bars after it slide left to close
/// the gap; the bar detaches at the end and everything restores on rewind.
@MainActor
final class BarRemoveTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let index: Int
    private var removed: Bar?
    private var removedDatum: BarDatum?
    private var trailingFromX: [ObjectIdentifier: Real] = [:]
    private var trailing: [Bar] = []

    init(
        entity: Entity, index: Int, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.index = index
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard removed == nil, let chart = entity as? BarChart,
              chart.bars.indices.contains(index) else { return }
        let bar = chart.bars[index]
        removed = bar
        removedDatum = bar.datum
        trailing = Array(chart.bars[(index + 1)...])
        for other in trailing {
            trailingFromX[ObjectIdentifier(other)] = other.position.x
        }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let chart = entity as? BarChart, let removed, let removedDatum else { return }
        let t = progress(at: clipTime, easing: easing)

        if t >= 1 {
            if chart.bars.contains(where: { $0 === removed }) {
                chart.detachBar(removed)
            }
        } else if !chart.bars.contains(where: { $0 === removed }) {
            chart.attachBar(removed, at: index)
        }
        if t < 1 {
            removed.apply(BarDatum.lerp(
                removedDatum, BarDatum(removedDatum.label, 0, error: removedDatum.error.map { _ in 0 }), t
            ))
        }
        for other in trailing {
            guard let fromX = trailingFromX[ObjectIdentifier(other)] else { continue }
            other.position.x = fromX - chart.slotStride * t
            other.refreshErrorBar()
        }
    }

    func rewind(in scene: Scene) {
        guard let chart = entity as? BarChart, let removed, let removedDatum else { return }
        if !chart.bars.contains(where: { $0 === removed }) {
            chart.attachBar(removed, at: index)
        }
        removed.position = Position(chart.slotX(index), 0, 0)
        removed.apply(removedDatum)
        for other in trailing {
            guard let fromX = trailingFromX[ObjectIdentifier(other)] else { continue }
            other.position.x = fromX
            other.refreshErrorBar()
        }
    }
}
