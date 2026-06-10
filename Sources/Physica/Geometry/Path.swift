// Path — 2D vector geometry (XY plane) built from line/quad/cubic segments.
// TrueType glyphs (quadratic) and shape builders (cubic) both lower into this.

public struct Path: Sendable, Equatable {
    public enum Segment: Sendable, Equatable {
        case line(to: SIMD2<Real>)
        case quadCurve(control: SIMD2<Real>, to: SIMD2<Real>)
        case curve(control1: SIMD2<Real>, control2: SIMD2<Real>, to: SIMD2<Real>)
    }

    public struct Contour: Sendable, Equatable {
        public var start: SIMD2<Real>
        public var segments: [Segment]
        public var isClosed: Bool

        public init(start: SIMD2<Real>, segments: [Segment] = [], isClosed: Bool = false) {
            self.start = start
            self.segments = segments
            self.isClosed = isClosed
        }
    }

    public var contours: [Contour]

    public init(contours: [Contour] = []) {
        self.contours = contours
    }

    public var isEmpty: Bool { contours.isEmpty }

    // MARK: Builders

    /// Circle approximated by 4 cubic Béziers (kappa = 0.5523).
    public static func circle(radius: Real, center: SIMD2<Real> = .zero) -> Path {
        let r = radius
        let k = r * 0.55228475
        let c = center
        let contour = Contour(
            start: SIMD2(c.x + r, c.y),
            segments: [
                .curve(control1: SIMD2(c.x + r, c.y + k), control2: SIMD2(c.x + k, c.y + r), to: SIMD2(c.x, c.y + r)),
                .curve(control1: SIMD2(c.x - k, c.y + r), control2: SIMD2(c.x - r, c.y + k), to: SIMD2(c.x - r, c.y)),
                .curve(control1: SIMD2(c.x - r, c.y - k), control2: SIMD2(c.x - k, c.y - r), to: SIMD2(c.x, c.y - r)),
                .curve(control1: SIMD2(c.x + k, c.y - r), control2: SIMD2(c.x + r, c.y - k), to: SIMD2(c.x + r, c.y)),
            ],
            isClosed: true
        )
        return Path(contours: [contour])
    }

    public static func rect(width: Real, height: Real, center: SIMD2<Real> = .zero) -> Path {
        let w = width / 2
        let h = height / 2
        return polygon(points: [
            SIMD2(center.x - w, center.y - h),
            SIMD2(center.x + w, center.y - h),
            SIMD2(center.x + w, center.y + h),
            SIMD2(center.x - w, center.y + h),
        ])
    }

    public static func polygon(points: [SIMD2<Real>], closed: Bool = true) -> Path {
        guard let first = points.first else { return Path() }
        let segments = points.dropFirst().map { Segment.line(to: $0) }
        return Path(contours: [Contour(start: first, segments: Array(segments), isClosed: closed)])
    }

    public static func line(from: SIMD2<Real>, to: SIMD2<Real>) -> Path {
        Path(contours: [Contour(start: from, segments: [.line(to: to)], isClosed: false)])
    }

    /// Arc as cubic Bézier segments (≤ 90° each). Angles in radians, CCW.
    public static func arc(
        center: SIMD2<Real>, radius: Real, startAngle: Real, endAngle: Real
    ) -> Path {
        let total = endAngle - startAngle
        guard Swift.abs(total) > 1e-6 else { return Path() }
        let segmentCount = Swift.max(1, Int((Swift.abs(total) / (Real.pi / 2)).rounded(.up)))
        let step = total / Real(segmentCount)

        func point(_ angle: Real) -> SIMD2<Real> {
            SIMD2(center.x + radius * Real.cos(angle), center.y + radius * Real.sin(angle))
        }

        var segments: [Segment] = []
        // Standard cubic arc approximation: control distance = 4/3 · tan(θ/4) · r.
        let control = 4 / 3 * Real.tan(step / 4) * radius
        for index in 0..<segmentCount {
            let a0 = startAngle + Real(index) * step
            let a1 = a0 + step
            let p0 = point(a0)
            let p3 = point(a1)
            let c1 = SIMD2(p0.x - control * Real.sin(a0), p0.y + control * Real.cos(a0))
            let c2 = SIMD2(p3.x + control * Real.sin(a1), p3.y - control * Real.cos(a1))
            segments.append(.curve(control1: c1, control2: c2, to: p3))
        }
        return Path(contours: [Contour(start: point(startAngle), segments: segments, isClosed: false)])
    }

    // MARK: Transform / merge

    public func translated(by delta: SIMD2<Real>) -> Path {
        transformedPoints { $0 + delta }
    }

    public func scaled(by factor: Real) -> Path {
        transformedPoints { $0 * factor }
    }

    public func transformedPoints(_ map: (SIMD2<Real>) -> SIMD2<Real>) -> Path {
        Path(contours: contours.map { contour in
            Contour(
                start: map(contour.start),
                segments: contour.segments.map { segment in
                    switch segment {
                    case .line(let to):
                        return .line(to: map(to))
                    case .quadCurve(let control, let to):
                        return .quadCurve(control: map(control), to: map(to))
                    case .curve(let c1, let c2, let to):
                        return .curve(control1: map(c1), control2: map(c2), to: map(to))
                    }
                },
                isClosed: contour.isClosed
            )
        })
    }

    public func appending(_ other: Path) -> Path {
        Path(contours: contours + other.contours)
    }

    /// Bounds of the flattened outline (z = 0 plane).
    public var bounds: Bounds {
        var result = Bounds.empty
        for contour in flattened() {
            for point in contour.points {
                result = result.union(Position(point.x, point.y, 0))
            }
        }
        return result
    }

    public var debugString: String {
        let counts = contours.map { "\($0.segments.count)\($0.isClosed ? "c" : "o")" }
        return "path[\(counts.joined(separator: ", "))]"
    }
}
