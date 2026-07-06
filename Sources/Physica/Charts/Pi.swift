// PieChart — a standalone pie chart: a `Group` of `Wedge` children (one filled
// sector per slice), laid out clockwise from 12 o'clock as fractions of the
// value total. Every mutation is an Animation, scrub-safe by the track
// contract:
//   pie.set(newSlices)   — shares morph in place (angles renormalize)
//   pie.add(slice)       — a new wedge grows in while the others make room
//   pie.remove(at: i)    — the wedge collapses and the others reclaim its arc

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

/// One slice's authored datum.
public struct PieSlice: Sendable {
    public var label: String
    public var value: Real
    /// nil → the chart palette assigns by index.
    public var color: Color?

    public init(_ label: String = "", _ value: Real, color: Color? = nil) {
        self.label = label
        self.value = value
        self.color = color
    }
}

/// One wedge: a filled circular sector, rebuilt from (startAngle, sweep).
@MainActor
public final class Wedge: PathEntity {
    public internal(set) var slice: PieSlice
    let radius: Real
    public private(set) var startAngle: Real = 0
    public private(set) var sweep: Real = 0

    init(slice: PieSlice, radius: Real, color: Color) {
        self.slice = slice
        self.radius = radius
        super.init(
            path: Path(),
            style: RenderStyleComponent(color: color, isFilled: true)
        )
        name = slice.label.isEmpty ? "wedge" : slice.label
    }

    func apply(startAngle: Real, sweep: Real) {
        self.startAngle = startAngle
        self.sweep = sweep
        path = .sector(
            center: .zero, radius: radius,
            startAngle: startAngle, endAngle: startAngle + sweep
        )
    }
}

@MainActor
public final class PieChart: Group {
    public let radius: Real
    public private(set) var wedges: [Wedge] = []

    /// Slice colors when the authored slice doesn't pick one (by index).
    public static let palette: [Color] = [
        Color(hex: 0x5B8CFF), Color(hex: 0x4CC878), Color(hex: 0xFFB040),
        Color(hex: 0xE05C6E), Color(hex: 0x9A6BFF), Color(hex: 0x53D3E0),
    ]

    /// The live slices, read from the wedges (mid-animation included).
    public var slices: [PieSlice] { wedges.map(\.slice) }

    public init(slices: [PieSlice], radius: Real = 1.5) {
        self.radius = radius
        super.init()
        name = "pieChart"
        for slice in slices {
            let wedge = makeWedge(slice, index: wedges.count)
            attachWedge(wedge, at: wedges.count)
        }
        applyValues(wedges.map(\.slice.value))
    }

    func makeWedge(_ slice: PieSlice, index: Int) -> Wedge {
        Wedge(
            slice: slice, radius: radius,
            color: slice.color ?? Self.palette[index % Self.palette.count]
        )
    }

    func attachWedge(_ wedge: Wedge, at index: Int) {
        guard !wedges.contains(where: { $0 === wedge }) else { return }
        let slot = Swift.min(index, wedges.count)
        insertChild(wedge, at: slot)
        wedges.insert(wedge, at: slot)
    }

    func detachWedge(_ wedge: Wedge) {
        removeChild(wedge)
        wedges.removeAll { $0 === wedge }
    }

    /// Sector layout for a value list: fractions of the total, clockwise from
    /// 12 o'clock (negative sweeps in CCW-positive math coordinates).
    static func layout(for values: [Real]) -> [(start: Real, sweep: Real)] {
        let total = Swift.max(values.reduce(0) { $0 + Swift.max($1, 0) }, 1e-9)
        var cursor = Real.pi / 2
        return values.map { value in
            let sweep = -2 * Real.pi * Swift.max(value, 0) / total
            defer { cursor += sweep }
            return (cursor, sweep)
        }
    }

    /// Applies values index-paired onto the live wedges (angles renormalize).
    func applyValues(_ values: [Real]) {
        let layout = Self.layout(for: values)
        for (index, wedge) in wedges.enumerated() where index < layout.count {
            wedge.slice.value = values[index]
            wedge.apply(startAngle: layout[index].start, sweep: layout[index].sweep)
        }
    }

    // MARK: Animations

    /// Morphs the shares to `newSlices`' values (index-paired).
    @discardableResult
    public func set(_ newSlices: [PieSlice]) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: PieDataBlueprint(slices: newSlices)
        )])
    }

    /// Appends a wedge that grows in while the others make room.
    @discardableResult
    public func add(_ slice: PieSlice) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: PieInsertBlueprint(slice: slice)
        )])
    }

    /// Collapses the wedge at `index`; the others reclaim its arc.
    @discardableResult
    public func remove(at index: Int) -> Animation {
        Animation(pairs: [AnimationPair(
            target: self, blueprint: PieRemoveBlueprint(index: index)
        )])
    }
}

// MARK: - Blueprints

struct PieDataBlueprint: AnimationBlueprint {
    let slices: [PieSlice]
    var debugLabel: String { "set(pie)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PieDataTrack(
            entity: target, to: slices.map(\.value), duration: duration, offset: offset,
            easing: easing, label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

struct PieInsertBlueprint: AnimationBlueprint {
    let slice: PieSlice
    var debugLabel: String { "add(slice)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PieInsertTrack(
            entity: target, slice: slice, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

struct PieRemoveBlueprint: AnimationBlueprint {
    let index: Int
    var debugLabel: String { "remove(slice)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PieRemoveTrack(
            entity: target, index: index, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

// MARK: - Tracks

/// Lerps every wedge's value; the layout renormalizes per frame.
@MainActor
final class PieDataTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [Real]
    private var from: [Real]?

    init(
        entity: Entity, to: [Real], duration: TimeInterval, offset: TimeInterval,
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
        guard from == nil, let pie = entity as? PieChart else { return }
        from = pie.wedges.map(\.slice.value)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let pie = entity as? PieChart, let from else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 { pie.applyValues(from); return }
        if t >= 1 { pie.applyValues(to); return }
        let count = Swift.min(from.count, to.count)
        pie.applyValues((0..<count).map { Real.lerp(from[$0], to[$0], t) })
    }

    func rewind(in scene: Scene) {
        if let from, let pie = entity as? PieChart {
            pie.applyValues(from)
        }
    }
}

/// Appends a wedge whose share grows from zero while the others compress.
@MainActor
final class PieInsertTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let slice: PieSlice
    private var wedge: Wedge?
    private var index = 0
    private var fromValues: [Real]?

    init(
        entity: Entity, slice: PieSlice, duration: TimeInterval, offset: TimeInterval,
        easing: Easing, label: String
    ) {
        self.entity = entity
        self.slice = slice
        self.duration = max(duration, 0)
        self.offset = max(offset, 0)
        self.easing = easing
        self.label = label
    }

    func begin(in scene: Scene) {
        guard wedge == nil, let pie = entity as? PieChart else { return }
        index = pie.wedges.count
        wedge = pie.makeWedge(slice, index: index)
        fromValues = pie.wedges.map(\.slice.value)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let pie = entity as? PieChart, let wedge, let fromValues else { return }
        if !pie.wedges.contains(where: { $0 === wedge }) {
            pie.attachWedge(wedge, at: index)
        }
        let t = progress(at: clipTime, easing: easing)
        pie.applyValues(fromValues + [slice.value * t])
    }

    func rewind(in scene: Scene) {
        guard let pie = entity as? PieChart, let wedge, let fromValues else { return }
        pie.detachWedge(wedge)
        pie.applyValues(fromValues)
    }
}

/// Collapses the wedge at `index`; detaches at the end, restores on rewind.
@MainActor
final class PieRemoveTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let index: Int
    private var removed: Wedge?
    private var fromValues: [Real]?

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
        guard removed == nil, let pie = entity as? PieChart,
              pie.wedges.indices.contains(index) else { return }
        removed = pie.wedges[index]
        fromValues = pie.wedges.map(\.slice.value)
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let pie = entity as? PieChart, let removed, let fromValues else { return }
        let t = progress(at: clipTime, easing: easing)

        if t >= 1 {
            if pie.wedges.contains(where: { $0 === removed }) {
                pie.detachWedge(removed)
            }
            var remaining = fromValues
            remaining.remove(at: index)
            pie.applyValues(remaining)
            return
        }
        if !pie.wedges.contains(where: { $0 === removed }) {
            pie.attachWedge(removed, at: index)
        }
        var values = fromValues
        values[index] *= (1 - t)
        pie.applyValues(values)
    }

    func rewind(in scene: Scene) {
        guard let pie = entity as? PieChart, let removed, let fromValues else { return }
        if !pie.wedges.contains(where: { $0 === removed }) {
            pie.attachWedge(removed, at: index)
        }
        pie.applyValues(fromValues)
    }
}
