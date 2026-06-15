// SceneCamera — the camera as an animatable entity (Manim's `self.camera.frame`).
//
// `scene.frame` is a proxy Entity whose transform reads/writes
// `scene.camera.transform` directly, so the whole existing animation surface —
// move/shift/rotate, PropertyTrack, saveState/restoreState, the scrub
// contract — drives the camera unchanged:
//
//     scene.play(scene.frame.move(to: 6.i), scene.frame.zoom(to: 5), for: 1.5.s)
//
// The proxy never joins the scene graph (no geometry, never rendered).
// Note: `move(to: Unit)` resolves against the camera frame itself, which is
// self-referential — it's shadowed as unavailable; use `move(to: Position)`
// or `focus(on:)`.

@MainActor
public final class SceneCamera: Entity {
    private unowned let owner: Scene

    init(scene: Scene) {
        self.owner = scene
        super.init()
        name = "camera"
    }

    /// Writes through to `scene.camera.transform` — no component storage.
    public override var transform: Transform {
        get { owner.camera.transform }
        set { owner.camera.transform = newValue }
    }

    /// The projection's animatable size scalar: `orthographicFit` extent,
    /// `orthographic` height, or `perspective` vertical FOV in degrees —
    /// whichever the camera currently uses.
    public var zoomExtent: Real {
        get {
            switch owner.camera.projection {
            case .orthographicFit(let extent): return extent
            case .orthographic(let height): return height
            case .perspective(let fov): return fov
            }
        }
        set {
            switch owner.camera.projection {
            case .orthographicFit: owner.camera.projection = .orthographicFit(extent: newValue)
            case .orthographic: owner.camera.projection = .orthographic(height: newValue)
            case .perspective: owner.camera.projection = .perspective(fovYDegrees: newValue)
            }
        }
    }

    /// Animate the projection scalar to an absolute size (smaller = closer).
    @discardableResult
    public func zoom(to extent: Real) -> Animation {
        Animation(pairs: [AnimationPair(target: self, blueprint: ZoomBlueprint(factor: extent, isRelative: false))])
    }

    /// Animate the projection scalar by a factor (0.5 = twice as close).
    @discardableResult
    public func zoom(by factor: Real) -> Animation {
        Animation(pairs: [AnimationPair(target: self, blueprint: ZoomBlueprint(factor: factor, isRelative: true))])
    }

    /// Center on `target` and size the frame to its bounds × `margin`
    /// (1 = exact fit). Both resolve at clip begin, like `move(to: Unit)`.
    @discardableResult
    public func focus(on target: Entity, margin: Real = 1.5) -> Animation {
        Animation(pairs: [
            AnimationPair(target: self, blueprint: FocusMoveBlueprint(subject: target)),
            AnimationPair(target: self, blueprint: FocusZoomBlueprint(subject: target, margin: margin)),
        ])
    }

    /// Animate back to the default framing — origin-centered at the default
    /// camera distance, `orthographicFit(extent: 10)`. The clean inverse of an
    /// ad-hoc `shift`/`zoom`: it composes like the other camera blueprints, so
    /// `scene.play(scene.frame.reset(), for: 1.2.s)` is one scrubbable clip
    /// (the zoom snaps within the current projection kind, like `zoom(to:)`).
    @discardableResult
    public func reset() -> Animation {
        let home = Camera()  // the documented default framing
        let homeExtent: Real
        switch home.projection {
        case .orthographicFit(let v), .orthographic(let v), .perspective(let v): homeExtent = v
        }
        return Animation(pairs: [
            AnimationPair(target: self, blueprint: MoveBlueprint(destination: home.transform.position)),
            AnimationPair(target: self, blueprint: ZoomBlueprint(factor: homeExtent, isRelative: false)),
        ])
    }

    /// Unit moves resolve against the camera frame itself — self-referential.
    @available(*, unavailable, message: "scene.frame can't move to a frame edge of itself; use move(to: Position) or focus(on:)")
    public func move(to unit: Unit, padding: Real = 0.5) -> Animation {
        Animation(pairs: [])
    }

    public override var debugString: String {
        "SceneCamera pos\(fmt(transform.position)) zoom \(fmt(zoomExtent, decimals: 2))"
    }
}

// MARK: - Blueprints

struct ZoomBlueprint: AnimationBlueprint {
    let factor: Real
    let isRelative: Bool
    var debugLabel: String { isRelative ? "zoom(by: \(fmt(factor, decimals: 2)))" : "zoom(to: \(fmt(factor, decimals: 2)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { ($0 as? SceneCamera)?.zoomExtent ?? 1 },
            write: { ($0 as? SceneCamera)?.zoomExtent = $1 },
            resolveEnd: { _, start in isRelative ? start * factor : factor }
        )
    }
}

struct FocusMoveBlueprint: AnimationBlueprint {
    let subject: Entity
    var debugLabel: String { "focus(on: \(name(of: subject)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Position>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { $0.position },
            write: { $0.position = $1 },
            // Keep the camera's own z — only the framing plane recenters.
            resolveEnd: { [weak subject] _, start in
                guard let subject else { return start }
                let center = subject.worldBounds.center
                return Position(center.x, center.y, start.z)
            }
        )
    }
}

struct FocusZoomBlueprint: AnimationBlueprint {
    let subject: Entity
    let margin: Real
    var debugLabel: String { "focusZoom(on: \(name(of: subject)))" }

    func makeTrack(
        target: Entity, duration: TimeInterval, offset: TimeInterval, easing: Easing, in scene: Scene
    ) -> any AnimationTrackProtocol {
        PropertyTrack<Real>(
            target: target, duration: duration, offset: offset, easing: easing,
            label: "\(name(of: target)).\(debugLabel)",
            read: { ($0 as? SceneCamera)?.zoomExtent ?? 1 },
            write: { ($0 as? SceneCamera)?.zoomExtent = $1 },
            resolveEnd: { [weak scene, weak subject] _, start in
                guard let scene, let subject else { return start }
                return Self.extent(
                    fitting: subject.worldBounds, margin: margin,
                    projection: scene.camera.projection,
                    cameraZ: scene.camera.transform.position.z,
                    aspect: scene.viewportAspect
                )
            }
        )
    }

    /// The zoom scalar that fits `bounds` × `margin` for the active projection.
    static func extent(
        fitting bounds: Bounds, margin: Real, projection: Camera.Projection, cameraZ: Real, aspect: Real
    ) -> Real {
        let needWidth = max(bounds.size.x * margin, 1e-3)
        let needHeight = max(bounds.size.y * margin, 1e-3)
        switch projection {
        case .orthographicFit:
            // Longest visible side = extent: w = E, h = E/aspect (aspect ≥ 1).
            return aspect >= 1
                ? max(needWidth, needHeight * aspect)
                : max(needHeight, needWidth / aspect)
        case .orthographic:
            // Visible height = E, width = E·aspect.
            return max(needHeight, needWidth / aspect)
        case .perspective:
            let distance = max(Swift.abs(cameraZ - bounds.center.z), 1e-3)
            let height = max(needHeight, needWidth / aspect)
            // atan(h/2d) — atan2 stands in (the distance is always positive).
            return 2 * Real.atan2(height / 2, distance) * 180 / .pi
        }
    }
}
