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
    /// (Internal, not private: the plot factories in SampledEntities.swift call it.)
    func sampleValues(in range: ClosedRange<Real>, step: Real, offset: Real = 0) -> [Real] {
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
