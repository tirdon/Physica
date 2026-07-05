// Scene-relative placement targets: edges, corners, center.
// `entity.move(to: .bottom)` resolves against the camera's visible rect at clip start.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

public enum Unit: Sendable, Hashable, CaseIterable {
    case center
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    /// Direction from scene center toward this unit, components in {-1, 0, 1}.
    public var vector: Position {
        switch self {
        case .center: return Position(0, 0, 0)
        case .top: return Position(0, 1, 0)
        case .bottom: return Position(0, -1, 0)
        case .left: return Position(-1, 0, 0)
        case .right: return Position(1, 0, 0)
        case .topLeft: return Position(-1, 1, 0)
        case .topRight: return Position(1, 1, 0)
        case .bottomLeft: return Position(-1, -1, 0)
        case .bottomRight: return Position(1, -1, 0)
        }
    }

    /// Aliases matching physical wall placement.
    public static let ceiling = Unit.top
    public static let floor = Unit.bottom
}
