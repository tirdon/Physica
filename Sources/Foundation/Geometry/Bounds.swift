// Bounds — axis-aligned bounding box shared by paths, meshes, and (via the
// kernel) entity bounds. `empty` unions as a no-op.


public struct Bounds: Sendable, Equatable {
    public var min: Position
    public var max: Position

    public static let empty = Bounds(min: Position(.infinity, .infinity, .infinity),
                                     max: Position(-.infinity, -.infinity, -.infinity))

    public init(min: Position, max: Position) {
        self.min = min
        self.max = max
    }

    public init(center: Position, size: Position) {
        self.min = center - size / 2
        self.max = center + size / 2
    }

    public var isEmpty: Bool { min.x > max.x }
    public var center: Position { isEmpty ? .zero : (min + max) / 2 }
    public var size: Position { isEmpty ? .zero : max - min }

    /// The 8 box corners (every min/max combination); `empty` has none.
    public var corners: [Position] {
        if isEmpty { return [] }
        var result: [Position] = []
        result.reserveCapacity(8)
        for cx in [min.x, max.x] {
            for cy in [min.y, max.y] {
                for cz in [min.z, max.z] {
                    result.append(Position(cx, cy, cz))
                }
            }
        }
        return result
    }

    public func union(_ other: Bounds) -> Bounds {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return Bounds(
            min: Position(Swift.min(min.x, other.min.x), Swift.min(min.y, other.min.y), Swift.min(min.z, other.min.z)),
            max: Position(Swift.max(max.x, other.max.x), Swift.max(max.y, other.max.y), Swift.max(max.z, other.max.z))
        )
    }

    public func union(_ point: Position) -> Bounds {
        union(Bounds(min: point, max: point))
    }

    /// Bounds of the 8 transformed corners.
    public func transformed(by transform: Transform) -> Bounds {
        if isEmpty { return Bounds(min: transform.position, max: transform.position) }
        var result = Bounds.empty
        for cx in [min.x, max.x] {
            for cy in [min.y, max.y] {
                for cz in [min.z, max.z] {
                    result = result.union(transform.applying(to: Position(cx, cy, cz)))
                }
            }
        }
        return result
    }

    public func contains(_ point: Position) -> Bool {
        !isEmpty
            && point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }
}
