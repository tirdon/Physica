// MeshEntity — the 3D entity kind. Geometry lives in ModelComponent so the
// snapshot pass stays component-driven; the class is sugar over it (mirrors
// PathEntity/PathComponent).

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

public struct ModelComponent: Component {
    public var mesh: Mesh
    public var color: Color
    public var opacity: Real
    public var shading: Shading

    public init(mesh: Mesh, color: Color = .blue, opacity: Real = 1, shading: Shading = .lambert) {
        self.mesh = mesh
        self.color = color
        self.opacity = opacity
        self.shading = shading
    }

    public var debugString: String { mesh.debugString }
}

@MainActor
open class MeshEntity: Entity {
    public var mesh: Mesh {
        get { components[ModelComponent.self]?.mesh ?? Mesh(positions: [], normals: [], indices: []) }
        set {
            var component = components[ModelComponent.self] ?? ModelComponent(mesh: newValue)
            component.mesh = newValue
            components[ModelComponent.self] = component
        }
    }

    public init(mesh: Mesh, color: Color = .blue) {
        super.init()
        components[ModelComponent.self] = ModelComponent(mesh: mesh, color: color)
    }

    /// `ball.shaded(.toon)` — chainable, like PathEntity's `stroke(_:width:)`.
    @discardableResult
    public func shaded(_ shading: Shading) -> Self {
        components[ModelComponent.self]?.shading = shading
        return self
    }

    public override init() {
        super.init()
    }

    open override var localBounds: Bounds {
        components[ModelComponent.self]?.mesh.bounds ?? .empty
    }
}
