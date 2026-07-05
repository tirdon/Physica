// The transform component — the pose (TRS) every entity carries. The pure
// value it wraps (Transform) lives below the kernel in PhysicaMath.

import PhysicaMath

public struct TransformComponent: Component {
    public var transform: Transform

    public init(transform: Transform = .identity) {
        self.transform = transform
    }

    public var debugString: String { transform.debugDescription }
}
