// Path flattening with deterministic subdivision counts (stable for tests and
// morph topology), plus arc-length resampling used by morphs and Write reveals.


public struct FlattenedContour: Sendable, Equatable {
    public var points: [SIMD2<Real>]
    public var isClosed: Bool

    public init(points: [SIMD2<Real>], isClosed: Bool) {
        self.points = points
        self.isClosed = isClosed
    }

    public var totalLength: Real {
        guard points.count > 1 else { return 0 }
        var length: Real = 0
        for index in 1..<points.count {
            length += (points[index] - points[index - 1]).distance()
        }
        if isClosed, let first = points.first, let last = points.last {
            length += (first - last).distance()
        }
        return length
    }

    /// Resamples to exactly `count` points, uniformly by arc length.
    public func resampled(count: Int) -> FlattenedContour {
        guard count >= 2, points.count >= 2 else { return self }
        var source = points
        if isClosed, let first = points.first {
            source.append(first)  // include the closing edge in the walk
        }

        var cumulative: [Real] = [0]
        for index in 1..<source.count {
            cumulative.append(cumulative[index - 1] + (source[index] - source[index - 1]).distance())
        }
        let total = cumulative[cumulative.count - 1]
        guard total > 0 else {
            return FlattenedContour(points: Array(repeating: source[0], count: count), isClosed: isClosed)
        }

        // For closed contours the implicit closing edge means `count` distinct samples;
        // for open ones the last sample lands exactly on the final point.
        let divisor = Real(isClosed ? count : count - 1)
        var result: [SIMD2<Real>] = []
        result.reserveCapacity(count)
        var cursor = 1
        for index in 0..<count {
            let target = total * Real(index) / divisor
            while cursor < source.count - 1, cumulative[cursor] < target {
                cursor += 1
            }
            let span = cumulative[cursor] - cumulative[cursor - 1]
            let t = span > 0 ? (target - cumulative[cursor - 1]) / span : 0
            result.append(SIMD2<Real>.lerp(source[cursor - 1], source[cursor], t))
        }
        return FlattenedContour(points: result, isClosed: isClosed)
    }
}

extension SIMD2<Real> {
    package func distance() -> Real {
        (x * x + y * y).squareRoot()
    }
}

public extension Path {
    /// Deterministic flattening: quads → 8 segments, cubics → 12, lines stay lines.
    func flattened() -> [FlattenedContour] {
        contours.compactMap { contour in
            var points: [SIMD2<Real>] = [contour.start]
            var current = contour.start

            for segment in contour.segments {
                switch segment {
                case .line(let to):
                    points.append(to)
                    current = to
                case .quadCurve(let control, let to):
                    for step in 1...8 {
                        let t = Real(step) / 8
                        points.append(Self.quadPoint(current, control, to, t))
                    }
                    current = to
                case .curve(let c1, let c2, let to):
                    for step in 1...12 {
                        let t = Real(step) / 12
                        points.append(Self.cubicPoint(current, c1, c2, to, t))
                    }
                    current = to
                }
            }

            // Closed contours drop a duplicated closing point; the edge is implicit.
            if contour.isClosed, points.count > 1,
               (points[0] - points[points.count - 1]).distance() < 1e-6 {
                points.removeLast()
            }
            guard points.count > 1 else { return nil }
            return FlattenedContour(points: points, isClosed: contour.isClosed)
        }
    }

    static func quadPoint(
        _ p0: SIMD2<Real>, _ control: SIMD2<Real>, _ p1: SIMD2<Real>, _ t: Real
    ) -> SIMD2<Real> {
        let u = 1 - t
        return u * u * p0 + 2 * u * t * control + t * t * p1
    }

    static func cubicPoint(
        _ p0: SIMD2<Real>, _ c1: SIMD2<Real>, _ c2: SIMD2<Real>, _ p1: SIMD2<Real>, _ t: Real
    ) -> SIMD2<Real> {
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return a * p0 + b * c1 + c * c2 + d * p1
    }
}
