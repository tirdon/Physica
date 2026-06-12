// Plotting — a chartboard Plane (grid + axes) that maps data coordinates to
// world space, plus the entities that live on it: function/data graphs, vector
// fields, and streamlines. All of them keep their sample data, and re-plotting
// is an Animation: `scene.play(graph.plot { x in .cos(x) })` morphs the data.
//
// Graphs/fields/streamlines are standalone entities sampled in the plane's
// space at creation (they copy its transform). Reveal them like any shape
// (`scene.add` / `.draw`); to move them with the plane, group explicitly:
// `Group(plane, graph).move(to: .left)` — no implicit coupling.

// MARK: - Axis options

/// Styling knobs for a `Plane`'s axes and labels — set at init or live via
/// `plane.axis` (assignment rebuilds the board geometry in place).
public struct AxisOptions: Sendable, Equatable {
    /// How far the axis lines run past the data range (world units).
    public var overhang: Real
    /// Tick half-length (ticks cross the axis line); world units.
    public var tickLength: Real
    /// Arrow-tip size at the positive axis ends; 0 removes the tips.
    public var tipLength: Real
    public var showTicks: Bool
    public var showLabels: Bool
    /// Show the "0" at the axis crossing (only when both ranges contain zero).
    public var showOriginLabel: Bool
    /// Font size of the tick-label TextEntities.
    public var labelSize: Real

    public init(
        overhang: Real = 0.3,
        tickLength: Real = 0.07,
        tipLength: Real = 0.18,
        showTicks: Bool = true,
        showLabels: Bool = true,
        showOriginLabel: Bool = true,
        labelSize: Real = 0.24
    ) {
        self.overhang = overhang
        self.tickLength = tickLength
        self.tipLength = tipLength
        self.showTicks = showTicks
        self.showLabels = showLabels
        self.showOriginLabel = showOriginLabel
        self.labelSize = labelSize
    }
}

// MARK: - Plane

/// Coordinate plane for charts and graphs: a faint grid lattice under two
/// Arrow-entity axes (`plane.xAxis` / `plane.yAxis` — adjust them directly)
/// with tick marks, plus TextEntity tick labels when a font is provided. Data coordinates map through `point(x, y)`; by default
/// 1 data unit = 1 world unit — rescale with `.size(6, 3)` /
/// `.size(6, aspect: 2)` (before sampling graphs). Axis styling is adjustable
/// via `plane.axis`, live.
@MainActor
public final class Plane: Group {
    public let xRange: ClosedRange<Real>
    public let yRange: ClosedRange<Real>
    public let gridStep: Real
    /// Minor lattice lines between grid steps (`subdivisions` per cell),
    /// fainter than `grid` — the depth cue that makes the board read as a
    /// chart instead of graph paper.
    public let subgrid: PathEntity
    /// Faint lattice — style/draw it separately from the axes.
    public let grid: PathEntity
    /// The axis lines are real `Arrow` entities — grab them to adjust later
    /// (`start`/`end`/`headLength`/`headWidth`/style are all live). Assigning
    /// `plane.axis` re-applies the options over direct tweaks.
    public let xAxis: Arrow
    public let yAxis: Arrow
    /// Tick marks, rebuilt from `axis` options.
    public let ticks: PathEntity
    /// xAxis + yAxis + ticks under one group (`scene.add(plane.axes)`).
    public let axes: Group
    /// Numeric tick labels: a TextEntity per tick value, placed at the tick
    /// points. Built when a `labelFont` is set; reveal with
    /// `scene.add(plane.labels)`. Contains `xLabels` + `yLabels`.
    public let labels: Group
    /// X-axis tick labels in axis order — `plane.xLabels[0].color(.red)`.
    public let xLabels: Group
    /// Y-axis tick labels in axis order (bottom to top).
    public let yLabels: Group
    /// The "0" below-left of the axis crossing — nil without a font, when
    /// labels are hidden, or when the ranges don't contain zero.
    public private(set) var originLabel: TextEntity?

    /// Axis styling; assigning rebuilds axes/labels in place.
    public var axis: AxisOptions {
        didSet { rebuildBoard() }
    }

    /// Font for the tick labels; assigning (re)builds them. Without a font the
    /// labels group stays empty — the board itself never needs one.
    public var labelFont: Font? {
        didSet { rebuildBoard() }
    }

    /// World units per data unit on each axis.
    private(set) var unitScale: SIMD2<Real>
    private let dataCenter: SIMD2<Real>
    private let dataSpan: SIMD2<Real>
    /// World span of the plotting area.
    private var span: SIMD2<Real>
    private let axisColor: Color
    private let subdivisions: Int

    public init(
        x: ClosedRange<Real> = -4...4,
        y: ClosedRange<Real> = -2.5...2.5,
        gridStep: Real = 1,
        subdivisions: Int = 2,
        size: SIMD2<Real>? = nil,
        gridColor: Color = Color(hex: 0x3E5A6B),
        axisColor: Color = Color(hex: 0xDCE6EC),
        axis: AxisOptions = AxisOptions(),
        font: Font? = nil
    ) {
        self.xRange = x
        self.yRange = y
        self.gridStep = Swift.max(gridStep, 1e-3)
        self.subdivisions = Swift.max(subdivisions, 1)
        self.axis = axis
        self.axisColor = axisColor
        self.labelFont = font
        let span = SIMD2<Real>(
            Swift.max(x.upperBound - x.lowerBound, 1e-6),
            Swift.max(y.upperBound - y.lowerBound, 1e-6)
        )
        self.dataSpan = span
        let resolved = size ?? span
        self.span = resolved
        self.unitScale = SIMD2(resolved.x / span.x, resolved.y / span.y)
        self.dataCenter = SIMD2(
            (x.lowerBound + x.upperBound) / 2,
            (y.lowerBound + y.upperBound) / 2
        )

        let subgridEntity = PathEntity(
            path: Path(),
            style: RenderStyleComponent(
                color: gridColor, strokeColor: gridColor, strokeWidth: 0.007,
                isFilled: false, opacity: 0.25
            )
        )
        subgridEntity.name = "subgrid"
        self.subgrid = subgridEntity
        let gridEntity = PathEntity(
            path: Path(),
            style: RenderStyleComponent(
                color: gridColor, strokeColor: gridColor, strokeWidth: 0.012,
                isFilled: false, opacity: 0.55
            )
        )
        gridEntity.name = "grid"
        self.grid = gridEntity
        let xArrow = Arrow(start: .origin, end: Position(1, 0, 0), width: 0.02, color: axisColor)
        xArrow.name = "xAxis"
        xArrow.stroke(axisColor, width: 0.02, cap: .round)
        self.xAxis = xArrow
        let yArrow = Arrow(start: .origin, end: Position(0, 1, 0), width: 0.02, color: axisColor)
        yArrow.name = "yAxis"
        yArrow.stroke(axisColor, width: 0.02, cap: .round)
        self.yAxis = yArrow
        let ticksEntity = PathEntity(
            path: Path(),
            style: RenderStyleComponent(
                color: axisColor, strokeColor: axisColor, strokeWidth: 0.02,
                cap: .round, isFilled: false
            )
        )
        ticksEntity.name = "ticks"
        self.ticks = ticksEntity
        let axesGroup = Group()
        axesGroup.name = "axes"
        axesGroup.addChild(xArrow)
        axesGroup.addChild(yArrow)
        axesGroup.addChild(ticksEntity)
        self.axes = axesGroup
        let xLabelsGroup = Group()
        xLabelsGroup.name = "xLabels"
        self.xLabels = xLabelsGroup
        let yLabelsGroup = Group()
        yLabelsGroup.name = "yLabels"
        self.yLabels = yLabelsGroup
        let labelsGroup = Group()
        labelsGroup.name = "labels"
        labelsGroup.addChild(xLabelsGroup)
        labelsGroup.addChild(yLabelsGroup)
        self.labels = labelsGroup

        super.init()
        name = "plane"
        rebuildBoard()
        addChild(subgridEntity)
        addChild(gridEntity)
        addChild(axesGroup)
        addChild(labelsGroup)
    }

    // MARK: Sizing

    /// Rescales the plotting area to a world-unit span (chainable):
    /// `Plane(x: 0...10, y: 0...4).size(5, 2)`. Resize before sampling —
    /// existing graphs/fields keep the scale they were sampled with.
    @discardableResult
    public func size(_ width: Real, _ height: Real) -> Self {
        span = SIMD2(Swift.max(width, 1e-6), Swift.max(height, 1e-6))
        unitScale = SIMD2(span.x / dataSpan.x, span.y / dataSpan.y)
        rebuildBoard()
        return self
    }

    /// Width plus aspect ratio (`height = width / aspect`).
    @discardableResult
    public func size(_ width: Real, aspect: Real = 1) -> Self {
        size(width, width / Swift.max(aspect, 1e-6))
    }

    /// Width : height of the plotting area in world units.
    public var aspectRatio: Real { span.x / Swift.max(span.y, 1e-9) }

    // MARK: Coordinate mapping

    /// Data point → world position (the plane's transform applied).
    public func point(_ x: Real, _ y: Real) -> Position {
        let local = localPoint(x, y)
        return worldTransform.applying(to: Position(local.x, local.y, 0))
    }

    /// Data point → plane-local coordinates (centered on the range midpoints).
    func localPoint(_ x: Real, _ y: Real) -> SIMD2<Real> {
        SIMD2((x - dataCenter.x) * unitScale.x, (y - dataCenter.y) * unitScale.y)
    }

    /// Inverse mapping pieces — annotation tracking reads data back out of
    /// plane-local geometry (`Graph.value(at:)`).
    func dataY(fromLocalY y: Real) -> Real {
        y / unitScale.y + dataCenter.y
    }

    func localXValue(_ x: Real) -> Real {
        (x - dataCenter.x) * unitScale.x
    }

    /// Clamps a sampled value into the y range (graphs never leave the board);
    /// non-finite samples pin to the top edge.
    func clampedY(_ value: Real) -> Real {
        guard value.isFinite else { return yRange.upperBound }
        return Swift.min(Swift.max(value, yRange.lowerBound), yRange.upperBound)
    }

    // MARK: Ticks

    /// Tick values along each axis (grid-step multiples inside the range).
    public var xTickValues: [Real] { gridValues(in: xRange) }
    public var yTickValues: [Real] { gridValues(in: yRange) }

    /// World point of a tick mark on the x axis — hang custom annotations
    /// off these the same way the built-in labels do.
    public func tickPoint(x value: Real) -> Position {
        point(value, axisYData)
    }

    /// World point of a tick mark on the y axis.
    public func tickPoint(y value: Real) -> Position {
        point(axisXData, value)
    }

    /// Axes sit on zero when zero is in range, else hug the nearest edge.
    private var axisYData: Real { clampedY(0) }
    private var axisXData: Real {
        Swift.min(Swift.max(0, xRange.lowerBound), xRange.upperBound)
    }

    /// Multiples of `step` (shifted by `offset`) inside a range, FP-tolerant.
    private func sampleValues(in range: ClosedRange<Real>, step: Real, offset: Real = 0) -> [Real] {
        var values: [Real] = []
        var value = ((range.lowerBound - offset) / step).rounded(.up) * step + offset
        while value <= range.upperBound + 1e-6 {
            values.append(value)
            value += step
        }
        return values
    }

    private func gridValues(in range: ClosedRange<Real>) -> [Real] {
        sampleValues(in: range, step: gridStep)
    }

    /// Re-derives all child geometry from the current scale and axis options.
    private func rebuildBoard() {
        subgrid.path = buildSubgrid()
        grid.path = buildGrid()
        layoutAxes()
        ticks.path = buildTicks()
        rebuildLabels()
    }

    /// Minor lattice between the major lines (`subdivisions` per cell);
    /// values landing on a major line are skipped — they're drawn by `grid`.
    private func buildSubgrid() -> Path {
        guard subdivisions > 1 else { return Path() }
        let step = gridStep / Real(subdivisions)
        func isMajor(_ value: Real) -> Bool {
            let ratio = value / gridStep
            return Swift.abs(ratio - ratio.rounded()) < 1e-4
        }
        var contours: [Path.Contour] = []
        for gx in sampleValues(in: xRange, step: step) where !isMajor(gx) {
            let a = localPoint(gx, yRange.lowerBound)
            let b = localPoint(gx, yRange.upperBound)
            contours.append(Path.Contour(start: a, segments: [.line(to: b)]))
        }
        for gy in sampleValues(in: yRange, step: step) where !isMajor(gy) {
            let a = localPoint(xRange.lowerBound, gy)
            let b = localPoint(xRange.upperBound, gy)
            contours.append(Path.Contour(start: a, segments: [.line(to: b)]))
        }
        return Path(contours: contours)
    }

    private func buildGrid() -> Path {
        var contours: [Path.Contour] = []
        for gx in gridValues(in: xRange) {
            let a = localPoint(gx, yRange.lowerBound)
            let b = localPoint(gx, yRange.upperBound)
            contours.append(Path.Contour(start: a, segments: [.line(to: b)]))
        }
        for gy in gridValues(in: yRange) {
            let a = localPoint(xRange.lowerBound, gy)
            let b = localPoint(xRange.upperBound, gy)
            contours.append(Path.Contour(start: a, segments: [.line(to: b)]))
        }
        return Path(contours: contours)
    }

    /// Repositions the axis arrows (their own setters rebuild their paths);
    /// tips sit at the positive ends, sized from `axis.tipLength`.
    private func layoutAxes() {
        let head = axis.tipLength
        let xStart = localPoint(xRange.lowerBound, axisYData) - SIMD2(axis.overhang, 0)
        let xEnd = localPoint(xRange.upperBound, axisYData) + SIMD2(axis.overhang, 0)
        xAxis.start = Position(xStart.x, xStart.y, 0)
        xAxis.end = Position(xEnd.x, xEnd.y, 0)
        xAxis.headLength = head
        xAxis.headWidth = head * 1.1

        let yStart = localPoint(axisXData, yRange.lowerBound) - SIMD2(0, axis.overhang)
        let yEnd = localPoint(axisXData, yRange.upperBound) + SIMD2(0, axis.overhang)
        yAxis.start = Position(yStart.x, yStart.y, 0)
        yAxis.end = Position(yEnd.x, yEnd.y, 0)
        yAxis.headLength = head
        yAxis.headWidth = head * 1.1
    }

    private func buildTicks() -> Path {
        let tick = axis.tickLength
        guard axis.showTicks, tick > 1e-6 else { return Path() }
        var contours: [Path.Contour] = []
        for gx in gridValues(in: xRange) {
            let p = localPoint(gx, axisYData)
            contours.append(Path.Contour(
                start: SIMD2(p.x, p.y - tick), segments: [.line(to: SIMD2(p.x, p.y + tick))]
            ))
        }
        for gy in gridValues(in: yRange) {
            let p = localPoint(axisXData, gy)
            contours.append(Path.Contour(
                start: SIMD2(p.x - tick, p.y), segments: [.line(to: SIMD2(p.x + tick, p.y))]
            ))
        }
        return Path(contours: contours)
    }

    /// Tick labels: one shown TextEntity per tick value (zero skipped — it
    /// sits on the axes), centered below x ticks, right-aligned at y ticks.
    private func rebuildLabels() {
        for child in xLabels.children {
            xLabels.removeChild(child)
        }
        for child in yLabels.children {
            yLabels.removeChild(child)
        }
        if let originLabel {
            labels.removeChild(originLabel)
            self.originLabel = nil
        }
        guard let font = labelFont, axis.showLabels else { return }
        let tick: Real = axis.showTicks ? axis.tickLength : 0
        for gx in gridValues(in: xRange) where Swift.abs(gx) > 1e-6 {
            let label = makeLabel(tickText(gx), font: font)
            let p = localPoint(gx, axisYData)
            let halfHeight = label.localBounds.size.y / 2
            label.position = Position(p.x, p.y - tick - 0.08 - halfHeight, 0)
            xLabels.addChild(label)
        }
        for gy in gridValues(in: yRange) where Swift.abs(gy) > 1e-6 {
            let label = makeLabel(tickText(gy), font: font)
            let p = localPoint(axisXData, gy)
            let halfWidth = label.localBounds.size.x / 2
            label.position = Position(p.x - tick - 0.1 - halfWidth, p.y, 0)
            yLabels.addChild(label)
        }
        // The "0" the tick loops skip: tucked below-left of the true origin
        // (an edge-hugging axis crossing isn't (0,0) — no label there).
        if axis.showOriginLabel, xRange.contains(0), yRange.contains(0) {
            let label = makeLabel("0", font: font)
            let p = localPoint(0, 0)
            let half = label.localBounds.size / 2
            label.position = Position(
                p.x - tick - 0.08 - half.x, p.y - tick - 0.08 - half.y, 0
            )
            labels.addChild(label)
            originLabel = label
        }
    }

    private func makeLabel(_ text: String, font: Font) -> TextEntity {
        let label = TextEntity(
            text, font: font, fontSize: axis.labelSize, color: axisColor
        ).shown()
        if var style = label.components[RenderStyleComponent.self] {
            style.opacity = 0.85
            label.components[RenderStyleComponent.self] = style
        }
        return label
    }

    /// Whole values print as integers, everything else with one decimal.
    private func tickText(_ value: Real) -> String {
        let rounded = value.rounded()
        if Swift.abs(value - rounded) < 1e-4 {
            return String(Int(rounded))
        }
        return fmt(value, decimals: 1)
    }
}

// MARK: - Sampled path entities (polyline-backed, data-animatable)

/// PathEntity whose geometry is a bag of polylines (`lines`, plane-local
/// coordinates). Graphs and streamlines build on it; `PolylineMorphTrack`
/// lerps the sample points, which is what makes their data animatable.
@MainActor
open class SampledPathEntity: PathEntity {
    public internal(set) var lines: [[SIMD2<Real>]] = []

    func setLines(_ newLines: [[SIMD2<Real>]]) {
        lines = newLines
        path = Self.polylinePath(newLines)
    }

    static func polylinePath(_ lines: [[SIMD2<Real>]]) -> Path {
        Path(contours: lines.compactMap { points in
            guard let first = points.first, points.count >= 2 else { return nil }
            return Path.Contour(start: first, segments: points.dropFirst().map { .line(to: $0) })
        })
    }
}

/// A plotted curve: `plane.graph(of: { x in .sin(x) })` for functions, or
/// `plane.plot(points)` for data series. Re-plot with an Animation:
/// `scene.play(graph.plot { x in .cos(x) })`.
@MainActor
public final class Graph: SampledPathEntity {
    public let plane: Plane
    /// Data-space sample xs (fixed at creation for function graphs, so
    /// re-plots stay topology-identical and lerp pointwise).
    public let sampleXs: [Real]

    init(plane: Plane, sampleXs: [Real], lines: [[SIMD2<Real>]], color: Color, width: Real) {
        self.plane = plane
        self.sampleXs = sampleXs
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false
            )
        )
        name = "graph"
        transform = plane.worldTransform
        setLines(lines)
    }
}

/// Arrow lattice of a vector field. The field values (`vectors`, data space)
/// are the animatable data: `scene.play(field.plot { p in ... })` lerps them
/// and rebuilds the arrows each frame, so heads stay true mid-morph.
@MainActor
public final class VectorField: PathEntity {
    public let plane: Plane
    /// Data-space lattice the field is sampled on (fixed at creation).
    public let samplePoints: [SIMD2<Real>]
    public internal(set) var vectors: [SIMD2<Real>] = []
    /// Longest arrow, world units (a fraction of the lattice cell).
    private let maxLength: Real
    /// Saturation magnitude: |v| = reference draws at half `maxLength`.
    /// Captured at creation and reused by re-plots, so morphs don't renormalize.
    private let reference: Real

    init(
        plane: Plane, samplePoints: [SIMD2<Real>], vectors: [SIMD2<Real>],
        color: Color, width: Real
    ) {
        self.plane = plane
        self.samplePoints = samplePoints
        let cell = plane.gridStep * Swift.min(plane.unitScale.x, plane.unitScale.y)
        self.maxLength = cell * 0.84
        var meanMagnitude: Real = 0
        for vector in vectors {
            meanMagnitude += vector.distance()
        }
        meanMagnitude /= Real(Swift.max(vectors.count, 1))
        self.reference = Swift.max(meanMagnitude, 1e-6)
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                // Filled: the closed head triangles render solid (the open
                // shaft contours have no area, so the fill skips them).
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: true
            )
        )
        name = "field"
        transform = plane.worldTransform
        setVectors(vectors)
    }

    func setVectors(_ newVectors: [SIMD2<Real>]) {
        vectors = newVectors
        rebuildArrows()
    }

    /// Every sample emits shaft + head contours even when degenerate, so the
    /// contour count is constant and trim-reveals/morphs stay aligned.
    private func rebuildArrows() {
        var contours: [Path.Contour] = []
        contours.reserveCapacity(samplePoints.count * 2)
        for (index, point) in samplePoints.enumerated() {
            let p = plane.localPoint(point.x, point.y)
            let v = index < vectors.count ? vectors[index] : .zero
            let scaled = SIMD2(v.x * plane.unitScale.x, v.y * plane.unitScale.y)
            let magnitude = scaled.distance()
            // Smooth saturation: never exceeds maxLength, no per-plot renorm.
            let length = maxLength * magnitude / (magnitude + reference)
            let dir = magnitude > 1e-9 ? scaled / magnitude : SIMD2<Real>(1, 0)
            let normal = SIMD2<Real>(-dir.y, dir.x)
            let a = p - dir * (length / 2)
            let b = p + dir * (length / 2)
            let head = Swift.min(maxLength * 0.38, length * 0.6)
            // Shaft stops at the head's back; the head is a closed triangle
            // so the fill renders it solid.
            contours.append(Path.Contour(
                start: a, segments: [.line(to: b - dir * head)]
            ))
            contours.append(Path.Contour(
                start: b - dir * head + normal * (head * 0.5),
                segments: [.line(to: b), .line(to: b - dir * head - normal * (head * 0.5))],
                isClosed: true
            ))
        }
        path = Path(contours: contours)
    }
}

/// Streamlines of a vector field: fixed-step midpoint (RK2) integration from a
/// seed lattice. Topology is constant (lines freeze where they exit the board),
/// so re-plots lerp pointwise: `scene.play(lines.plot { p in ... })`.
@MainActor
public final class Streamlines: SampledPathEntity {
    public let plane: Plane
    public let seeds: [SIMD2<Real>]
    public let steps: Int
    public let dt: Real

    init(
        plane: Plane, seeds: [SIMD2<Real>], steps: Int, dt: Real,
        lines: [[SIMD2<Real>]], color: Color, width: Real
    ) {
        self.plane = plane
        self.seeds = seeds
        self.steps = steps
        self.dt = dt
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false, opacity: 0.8
            )
        )
        name = "streamlines"
        transform = plane.worldTransform
        setLines(lines)
    }
}

// MARK: - Plane factories

public extension Plane {
    /// Function graph `y = f(x)` sampled uniformly across the x range
    /// (values clamp to the y range). Reveal it like any shape; re-plot with
    /// `graph.plot { ... }`.
    @discardableResult
    func graph(
        of function: (Real) -> Real,
        samples: Int = 160,
        color: Color = .yellow,
        width: Real = 0.025
    ) -> Graph {
        let count = Swift.max(samples, 2)
        let xs = (0..<count).map { index in
            xRange.lowerBound
                + (xRange.upperBound - xRange.lowerBound) * Real(index) / Real(count - 1)
        }
        let points = xs.map { localPoint($0, clampedY(function($0))) }
        return Graph(plane: self, sampleXs: xs, lines: [points], color: color, width: width)
    }

    /// Data series as a polyline (line chart). Points are data coordinates.
    @discardableResult
    func plot(
        _ points: [SIMD2<Real>],
        color: Color = .yellow,
        width: Real = 0.025
    ) -> Graph {
        let line = points.map { localPoint($0.x, clampedY($0.y)) }
        return Graph(
            plane: self, sampleXs: points.map(\.x), lines: [line], color: color, width: width
        )
    }

    /// Vector field arrows on the grid lattice (`step` defaults to `gridStep`).
    /// Arrow length saturates with magnitude; direction is exact.
    @discardableResult
    func field(
        step: Real? = nil,
        color: Color = .teal,
        width: Real = 0.016,
        _ function: (SIMD2<Real>) -> SIMD2<Real>
    ) -> VectorField {
        let lattice = sampleLattice(step: Swift.max(step ?? gridStep, 1e-3), centered: false)
        let vectors = lattice.map { Self.sanitized(function($0)) }
        return VectorField(
            plane: self, samplePoints: lattice, vectors: vectors, color: color, width: width
        )
    }

    /// Streamlines seeded at cell centers (`seedStep` defaults to `gridStep`),
    /// integrated with fixed-step RK2 in data space.
    @discardableResult
    func streamlines(
        seedStep: Real? = nil,
        steps: Int = 90,
        dt: Real = 0.05,
        color: Color = .blue,
        width: Real = 0.014,
        _ function: (SIMD2<Real>) -> SIMD2<Real>
    ) -> Streamlines {
        let seeds = sampleLattice(step: Swift.max(seedStep ?? gridStep, 1e-3), centered: true)
        let lines = seeds.map { seed in
            integrate(function, from: seed, steps: Swift.max(steps, 1), dt: dt)
                .map { localPoint($0.x, $0.y) }
        }
        return Streamlines(
            plane: self, seeds: seeds, steps: Swift.max(steps, 1), dt: dt,
            lines: lines, color: color, width: width
        )
    }

    // MARK: Sampling helpers

    /// Lattice of data-space sample points; `centered` offsets by half a step
    /// (streamline seeds start inside cells, not on grid lines).
    private func sampleLattice(step: Real, centered: Bool) -> [SIMD2<Real>] {
        let offset = centered ? step / 2 : 0
        let xs = sampleValues(in: xRange, step: step, offset: offset)
        let ys = sampleValues(in: yRange, step: step, offset: offset)
        var lattice: [SIMD2<Real>] = []
        lattice.reserveCapacity(xs.count * ys.count)
        for y in ys {
            for x in xs {
                lattice.append(SIMD2(x, y))
            }
        }
        return lattice
    }

    /// Fixed-count RK2 walk; the point list always has `steps + 1` entries
    /// (frozen at the exit point once the line leaves the board), keeping
    /// every streamline's topology constant for morphing.
    func integrate(
        _ function: (SIMD2<Real>) -> SIMD2<Real>,
        from seed: SIMD2<Real>, steps: Int, dt: Real
    ) -> [SIMD2<Real>] {
        let maxStep = gridStep / 2
        var points: [SIMD2<Real>] = [seed]
        points.reserveCapacity(steps + 1)
        var p = seed
        var frozen = false
        for _ in 0..<steps {
            if !frozen {
                let k1 = Self.sanitized(function(p))
                let mid = p + k1 * (dt / 2)
                var delta = Self.sanitized(function(mid)) * dt
                let length = delta.distance()
                if length > maxStep { delta *= maxStep / length }
                let next = p + delta
                if xRange.contains(next.x) && yRange.contains(next.y) {
                    p = next
                } else {
                    frozen = true
                }
            }
            points.append(p)
        }
        return points
    }

    static func sanitized(_ vector: SIMD2<Real>) -> SIMD2<Real> {
        vector.x.isFinite && vector.y.isFinite ? vector : .zero
    }
}

// MARK: - Data re-plot animations

public extension Graph {
    /// Morphs the curve to a new function over the same sample xs — data is
    /// animatable like any property: `scene.play(graph.plot { x in .cos(x) })`.
    @discardableResult
    func plot(_ function: (Real) -> Real) -> Animation {
        let points = sampleXs.map { plane.localPoint($0, plane.clampedY(function($0))) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [points], verb: "plot(fn)")
        )])
    }

    /// Morphs to a new data series (sample counts may differ — resampled).
    @discardableResult
    func plot(_ points: [SIMD2<Real>]) -> Animation {
        let line = points.map { plane.localPoint($0.x, plane.clampedY($0.y)) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: [line], verb: "plot(data)")
        )])
    }

    // MARK: Annotation data access

    /// Current data value at `x`, read from the live polyline — mid-morph it
    /// returns the interpolated curve, so annotations track the animation.
    func value(at x: Real) -> Real {
        plane.dataY(fromLocalY: localPoint(atDataX: x).y)
    }

    /// World position on the curve at data `x` — drive a marker with an
    /// updater: `dot.updater = { $0.position = graph.point(at: 1.2) }`.
    func point(at x: Real) -> Position {
        let local = localPoint(atDataX: x)
        return worldTransform.applying(to: Position(local.x, local.y, 0))
    }

    /// Finds the bracketing sample pair on the live line (either x direction)
    /// and lerps; outside the sampled range clamps to the nearer end.
    private func localPoint(atDataX x: Real) -> SIMD2<Real> {
        let targetX = plane.localXValue(x)
        guard let line = lines.first, let first = line.first, let last = line.last else {
            return SIMD2(targetX, 0)
        }
        var previous = first
        for point in line.dropFirst() {
            let lower = Swift.min(previous.x, point.x)
            let upper = Swift.max(previous.x, point.x)
            if targetX >= lower - 1e-6 && targetX <= upper + 1e-6 {
                let span = point.x - previous.x
                let raw = Swift.abs(span) > 1e-9 ? (targetX - previous.x) / span : 0
                let t = Swift.min(Swift.max(raw, 0), 1)
                return SIMD2<Real>.lerp(previous, point, t)
            }
            previous = point
        }
        return Swift.abs(targetX - first.x) < Swift.abs(targetX - last.x) ? first : last
    }
}

public extension VectorField {
    /// Lerps the field values to a new function (sampled on the same lattice)
    /// and rebuilds the arrows every frame, so heads point true mid-morph.
    @discardableResult
    func plot(_ function: (SIMD2<Real>) -> SIMD2<Real>) -> Animation {
        let target = samplePoints.map { Plane.sanitized(function($0)) }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: VectorFieldBlueprint(vectors: target)
        )])
    }
}

public extension Streamlines {
    /// Re-integrates from the same seeds (identical topology) and lerps lines.
    @discardableResult
    func plot(_ function: (SIMD2<Real>) -> SIMD2<Real>) -> Animation {
        let lines = seeds.map { seed in
            plane.integrate(function, from: seed, steps: steps, dt: dt)
                .map { plane.localPoint($0.x, $0.y) }
        }
        return Animation(pairs: [AnimationPair(
            target: self, blueprint: PolylineMorphBlueprint(lines: lines, verb: "plot(flow)")
        )])
    }
}

// MARK: - Tracks

struct PolylineMorphBlueprint: AnimationBlueprint {
    let lines: [[SIMD2<Real>]]
    let verb: String
    var debugLabel: String { verb }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PolylineMorphTrack(
            entity: target, to: lines, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

/// Lerps polyline sample points index-to-index (no contour sorting — line N
/// stays line N, unlike `PathMorph`, which would scramble many-line bundles).
@MainActor
final class PolylineMorphTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [[SIMD2<Real>]]

    private var from: [[SIMD2<Real>]]?
    private var matchedFrom: [[SIMD2<Real>]]?
    private var matchedTo: [[SIMD2<Real>]]?

    init(
        entity: Entity, to: [[SIMD2<Real>]], duration: TimeInterval, offset: TimeInterval,
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
        guard from == nil, let sampled = entity as? SampledPathEntity else { return }
        let start = sampled.lines
        from = start
        let matched = Self.matched(start, to)
        matchedFrom = matched.from
        matchedTo = matched.to
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let sampled = entity as? SampledPathEntity,
              let from, let matchedFrom, let matchedTo else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 {
            sampled.setLines(from)  // exact sample data at both endpoints
            return
        }
        if t >= 1 {
            sampled.setLines(to)
            return
        }
        sampled.setLines(zip(matchedFrom, matchedTo).map { a, b in
            zip(a, b).map { SIMD2<Real>.lerp($0, $1, t) }
        })
    }

    func rewind(in scene: Scene) {
        if let from, let sampled = entity as? SampledPathEntity {
            sampled.setLines(from)
        }
    }

    /// Index-paired topology match: per-line arc-length resample to the larger
    /// count; a missing partner collapses to/grows from the existing line's
    /// first point.
    static func matched(
        _ a: [[SIMD2<Real>]], _ b: [[SIMD2<Real>]]
    ) -> (from: [[SIMD2<Real>]], to: [[SIMD2<Real>]]) {
        var from: [[SIMD2<Real>]] = []
        var to: [[SIMD2<Real>]] = []
        let count = Swift.max(a.count, b.count)
        for index in 0..<count {
            var lineA = index < a.count ? a[index] : []
            var lineB = index < b.count ? b[index] : []
            let anchorA = lineA.first ?? lineB.first ?? .zero
            let anchorB = lineB.first ?? lineA.first ?? .zero
            if lineA.count < 2 { lineA = [lineA.first ?? anchorB, lineA.first ?? anchorB] }
            if lineB.count < 2 { lineB = [lineB.first ?? anchorA, lineB.first ?? anchorA] }
            let resolved = Swift.max(lineA.count, lineB.count)
            from.append(
                FlattenedContour(points: lineA, isClosed: false).resampled(count: resolved).points
            )
            to.append(
                FlattenedContour(points: lineB, isClosed: false).resampled(count: resolved).points
            )
        }
        return (from, to)
    }
}

struct VectorFieldBlueprint: AnimationBlueprint {
    let vectors: [SIMD2<Real>]
    var debugLabel: String { "plot(field)" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        VectorFieldTrack(
            entity: target, to: vectors, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)"
        )
    }
}

/// Lerps the field's sample vectors; the entity rebuilds its arrows from them.
@MainActor
final class VectorFieldTrack: AnimationTrackProtocol {
    let duration: TimeInterval
    let offset: TimeInterval
    let label: String
    private let easing: Easing
    private let entity: Entity
    private let to: [SIMD2<Real>]
    private var from: [SIMD2<Real>]?

    init(
        entity: Entity, to: [SIMD2<Real>], duration: TimeInterval, offset: TimeInterval,
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
        guard from == nil, let field = entity as? VectorField else { return }
        from = field.vectors
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        guard let field = entity as? VectorField, let from else { return }
        let t = progress(at: clipTime, easing: easing)
        if t <= 0 { field.setVectors(from); return }
        if t >= 1 { field.setVectors(to); return }
        let count = Swift.min(from.count, to.count)
        field.setVectors((0..<count).map { SIMD2<Real>.lerp(from[$0], to[$0], t) })
    }

    func rewind(in scene: Scene) {
        if let from, let field = entity as? VectorField {
            field.setVectors(from)
        }
    }
}
