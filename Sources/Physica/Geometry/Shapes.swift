// PathEntity and the Manim-style shape vocabulary: Circle, Rectangle, Triangle,
// Line, Arrow, Wall. Geometry lives in PathComponent so the snapshot pass stays
// component-driven; the classes are sugar over it.

/// Vector geometry + reveal state (Write/draw animations cap these).
public struct PathComponent: Component {
    public var path: Path
    /// 0...1 — how much of the stroke is revealed (arc-length ordered).
    public var strokeProgress: Real
    /// 0...1 — trims the stroke's tail: only the span strokeStart...strokeProgress
    /// is drawn (highlight's chasing loop). 0 = whole stroke from its start.
    public var strokeStart: Real
    /// 0...1 — multiplies fill alpha (Write fades fill in after the stroke).
    public var fillOpacityFactor: Real

    public init(
        path: Path = Path(), strokeProgress: Real = 1, strokeStart: Real = 0,
        fillOpacityFactor: Real = 1
    ) {
        self.path = path
        self.strokeProgress = strokeProgress
        self.strokeStart = strokeStart
        self.fillOpacityFactor = fillOpacityFactor
    }

    public var debugString: String { path.debugString }
}

@MainActor
open class PathEntity: Entity {
    public var path: Path {
        get { components[PathComponent.self]?.path ?? Path() }
        set {
            var component = components[PathComponent.self] ?? PathComponent()
            component.path = newValue
            components[PathComponent.self] = component
            pathDidChange()
        }
    }

    public var style: RenderStyleComponent {
        get { components[RenderStyleComponent.self] ?? RenderStyleComponent() }
        set { components[RenderStyleComponent.self] = newValue }
    }

    public init(path: Path = Path(), style: RenderStyleComponent = RenderStyleComponent()) {
        super.init()
        components[PathComponent.self] = PathComponent(path: path)
        components[RenderStyleComponent.self] = style
    }

    public override init() {
        super.init()
        components[PathComponent.self] = PathComponent()
        components[RenderStyleComponent.self] = RenderStyleComponent()
    }

    /// Hook for subclasses that derive geometry from properties.
    open func pathDidChange() {}

    open override var localBounds: Bounds { path.bounds }

    // MARK: Style sugar (chainable)

    @discardableResult
    public func color(_ color: Color) -> Self {
        var style = self.style
        style.color = color
        self.style = style
        return self
    }

    @discardableResult
    public func stroke(_ color: Color?, width: Real = 0.04, cap: StrokeCap = .square) -> Self {
        var style = self.style
        style.strokeColor = color
        style.strokeWidth = width
        style.cap = cap
        self.style = style
        return self
    }

    @discardableResult
    public func filled(_ isFilled: Bool) -> Self {
        var style = self.style
        style.isFilled = isFilled
        self.style = style
        return self
    }
}

// MARK: - Shapes

@MainActor
public final class Circle: PathEntity {
    public private(set) var radius: Real

    public init(radius: Real = 0.5, color: Color = .blue) {
        self.radius = radius
        super.init(
            path: .circle(radius: radius),
            style: RenderStyleComponent(color: color)
        )
    }
}

@MainActor
public final class Rectangle: PathEntity {
    public private(set) var width: Real
    public private(set) var height: Real

    public init(width: Real = 1, height: Real = 1, color: Color = .teal) {
        self.width = width
        self.height = height
        super.init(
            path: .rect(width: width, height: height),
            style: RenderStyleComponent(color: color)
        )
    }
}

@MainActor
public final class Triangle: PathEntity {
    public init(side: Real = 1, color: Color = .orange) {
        // Equilateral, centroid at the origin.
        let r = side / Real(3).squareRoot()
        let top = SIMD2<Real>(0, r)
        let left = SIMD2<Real>(-side / 2, -r / 2)
        let right = SIMD2<Real>(side / 2, -r / 2)
        super.init(
            path: .polygon(points: [top, left, right]),
            style: RenderStyleComponent(color: color)
        )
    }
}

/// Straight segment between two mutable endpoints (in the entity's local space —
/// world coordinates while the transform stays identity, the common scripting case).
@MainActor
public final class Line: PathEntity {
    public var start: Position { didSet { rebuild() } }
    public var end: Position { didSet { rebuild() } }

    public init(start: Position, end: Position, width: Real = 0.04, color: Color = .white) {
        self.start = start
        self.end = end
        super.init(
            path: .line(from: SIMD2(start.x, start.y), to: SIMD2(end.x, end.y)),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width, isFilled: false
            )
        )
    }

    private func rebuild() {
        path = .line(from: SIMD2(start.x, start.y), to: SIMD2(end.x, end.y))
    }
}

/// Line with a solid triangular tip at the end point.
@MainActor
public final class Arrow: PathEntity {
    public var start: Position { didSet { rebuild() } }
    public var end: Position { didSet { rebuild() } }
    public var headLength: Real { didSet { rebuild() } }
    public var headWidth: Real { didSet { rebuild() } }

    public init(
        start: Position, end: Position,
        headLength: Real = 0.25, headWidth: Real = 0.18,
        width: Real = 0.04, color: Color = .yellow
    ) {
        self.start = start
        self.end = end
        self.headLength = headLength
        self.headWidth = headWidth
        super.init(
            path: Path(),
            style: RenderStyleComponent(color: color, strokeColor: color, strokeWidth: width)
        )
        rebuild()
    }

    private func rebuild() {
        let a = SIMD2<Real>(start.x, start.y)
        let b = SIMD2<Real>(end.x, end.y)
        let direction = b - a
        let length = direction.distance()
        guard length > 1e-6 else {
            path = Path()
            return
        }
        // Degenerate head → plain line (Plane axes use headLength 0 for
        // AxisOptions(tipLength: 0)).
        guard headLength > 1e-6 else {
            path = .line(from: a, to: b)
            return
        }
        let unit = direction / length
        let normal = SIMD2<Real>(-unit.y, unit.x)
        let shaftEnd = b - unit * headLength

        var result = Path.line(from: a, to: shaftEnd)
        result = result.appending(.polygon(points: [
            b,
            shaftEnd + normal * (headWidth / 2),
            shaftEnd - normal * (headWidth / 2),
        ]))
        path = result
    }
}

/// Hatched wall segment. `face` is the open side; `Wall(face: .down)` is a ceiling
/// and places itself at the top of the default camera frame.
@MainActor
public final class Wall: PathEntity {
    public enum Face: Sendable {
        case up, down, left, right

        var unit: Unit {
            switch self {
            case .up: return .bottom     // faces up → sits at the bottom edge
            case .down: return .top      // faces down → ceiling
            case .left: return .right
            case .right: return .left
            }
        }
    }

    public let face: Face
    public let length: Real
    private let surfaceBounds: Bounds

    public init(face: Face = .down, length: Real = 4, color: Color = .gray) {
        self.face = face
        self.length = length

        // Build in local space along x with the surface line on y = 0 and hatch
        // ticks on the closed side (opposite the face), then rotate per face.
        let half = length / 2
        var path = Path.line(from: SIMD2(-half, 0), to: SIMD2(half, 0))
        let hatchCount = Int(length / 0.35)
        let tick: Real = 0.22
        for index in 0...hatchCount {
            let x = -half + Real(index) * (length / Real(Swift.max(hatchCount, 1)))
            path = path.appending(.line(from: SIMD2(x, 0), to: SIMD2(x - tick * 0.6, tick)))
        }
        self.surfaceBounds = Bounds(
            min: Position(-half, -0.001, 0),
            max: Position(half, 0.001, 0)
        )

        super.init(
            path: path,
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: 0.035, isFilled: false
            )
        )

        // Orient so hatches point away from the face, and snap just inside the
        // default camera frame (fit-10 at aspect 1.6 → 10 × 6.25).
        switch face {
        case .down:
            transform.position = Position(0, 2.9, 0)
        case .up:
            transform.orientation = Quaternion(angle: .pi, axis: 1.k)
            transform.position = Position(0, -2.9, 0)
        case .right:
            transform.orientation = Quaternion(angle: .pi / 2, axis: 1.k)
            transform.position = Position(-4.6, 0, 0)
        case .left:
            transform.orientation = Quaternion(angle: -.pi / 2, axis: 1.k)
            transform.position = Position(4.6, 0, 0)
        }
    }

    /// The anchoring surface line only — hatch ticks don't shift `center`,
    /// so `pivot.center` is exactly the point a pendulum hangs from.
    public override var localBounds: Bounds { surfaceBounds }
}
