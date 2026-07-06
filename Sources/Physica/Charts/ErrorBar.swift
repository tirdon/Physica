// ErrorBar — the ±error I-beam that rides a chart element (a bar's top, a
// scatter point): a vertical whisker with end caps, stroke-only. Geometry is
// driven by `halfExtent` (world units), so the owning chart animates errors by
// writing that property; ~zero extent renders nothing (a datum without error).

import PhysicaFoundation
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class ErrorBar: PathEntity {
    /// Half the whisker's vertical span, in world units (± around `position`).
    public var halfExtent: Real { didSet { rebuild() } }
    /// Full width of the end caps.
    public var capWidth: Real { didSet { rebuild() } }

    public init(
        halfExtent: Real,
        capWidth: Real = 0.24,
        width: Real = 0.018,
        color: Color = .white
    ) {
        self.halfExtent = halfExtent
        self.capWidth = capWidth
        super.init(
            path: Path(),
            style: RenderStyleComponent(
                color: color, strokeColor: color, strokeWidth: width,
                cap: .round, isFilled: false
            )
        )
        name = "errorBar"
        rebuild()
    }

    private func rebuild() {
        guard halfExtent > 1e-6 else {
            path = Path()
            return
        }
        let h = halfExtent
        let c = capWidth / 2
        path = Path(contours: [
            Path.Contour(start: SIMD2(0, -h), segments: [.line(to: SIMD2(0, h))]),
            Path.Contour(start: SIMD2(-c, h), segments: [.line(to: SIMD2(c, h))]),
            Path.Contour(start: SIMD2(-c, -h), segments: [.line(to: SIMD2(c, -h))]),
        ])
    }
}
