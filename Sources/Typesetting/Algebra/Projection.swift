// Axis projection — the vector extension the Equalynx design doesn't have.
// The author of a problem declares each vector's scalar components once
// (g points down, T along the string…); projecting an equation substitutes
// every `.vector` by its declared component and simplifies, so zero
// components fold away:
//
//     \vec F = m\vec g + \vec T   --x-->   F_x = T\cos\theta
//                                 --y-->   0 = mg + T\sin\theta

public enum ProjectionAxis: Sendable, Equatable, Hashable {
    case x, y

    public var label: String { self == .x ? "x" : "y" }
}

/// Author-supplied per-vector scalar components, parsed eagerly so a typo
/// fails at table construction, not mid-drag.
public struct ComponentTable: Sendable {
    private var entries: [String: (x: Expression, y: Expression)] = [:]

    public init(_ components: [String: (x: String, y: String)]) throws {
        for (name, pair) in components {
            entries[name] = (
                x: try Expression(parsing: pair.x),
                y: try Expression(parsing: pair.y)
            )
        }
    }

    public func component(of vector: String, axis: ProjectionAxis) -> Expression? {
        guard let entry = entries[vector] else { return nil }
        return axis == .x ? entry.x : entry.y
    }

    public var vectorNames: [String] {
        entries.keys.sorted()
    }
}

public extension Expression {
    /// Substitute every vector by its declared component on `axis`. Throws
    /// `.unsupported` when a vector has no entry in the table.
    func projected(onto axis: ProjectionAxis, components: ComponentTable) throws -> Expression {
        switch self {
        case .number, .variable, .constant:
            return self
        case .vector(let name):
            guard let component = components.component(of: name, axis: axis) else {
                throw AlgebraError.unsupported(
                    "No \(axis.label) component declared for vector '\(name)'."
                )
            }
            return component
        case .unary(let op, let operand):
            return .unary(op, try operand.projected(onto: axis, components: components))
        case .binary(let op, let lhs, let rhs):
            return .binary(
                op,
                try lhs.projected(onto: axis, components: components),
                try rhs.projected(onto: axis, components: components)
            )
        case .function(let name, let argument):
            return .function(name: name, argument: try argument.projected(onto: axis, components: components))
        }
    }
}

public extension Equation {
    /// The scalar equation along `axis`: both sides substituted and
    /// simplified (m·0 vanishes, leaving the textbook component form).
    func projected(onto axis: ProjectionAxis, components: ComponentTable) throws -> Equation {
        Equation(
            lhs: try lhs.projected(onto: axis, components: components).simplified(),
            rhs: try rhs.projected(onto: axis, components: components).simplified()
        )
    }
}
