// AxisOptions — styling knobs for a `Plane`'s axes and labels. A top-level
// struct on purpose: nested in the @MainActor Plane class it would inherit
// actor isolation.

/// Styling knobs for a `Plane`'s axes and labels — set at init or live via
/// `plane.axis` (assignment rebuilds the board geometry in place).
import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

public struct AxisOptions: Sendable, Equatable {
    /// How far the axis lines run past the data range (world units).
    public var overhang: Real
    /// Tick half-length (ticks cross the axis line); world units.
    public var tickLength: Real
    /// Arrow-tip size at the positive axis ends; 0 removes the tips.
    public var tipLength: Real
    public var showTicks: Bool
    public var showLabels: Bool
    /// Show the "0" at the axis crossing (only when both ranges contain zero).
    public var showOriginLabel: Bool
    /// Font size of the tick-label TextEntities.
    public var labelSize: Real

    public init(
        overhang: Real = 0.3,
        tickLength: Real = 0.07,
        tipLength: Real = 0.18,
        showTicks: Bool = true,
        showLabels: Bool = true,
        showOriginLabel: Bool = true,
        labelSize: Real = 0.24
    ) {
        self.overhang = overhang
        self.tickLength = tickLength
        self.tipLength = tipLength
        self.showTicks = showTicks
        self.showLabels = showLabels
        self.showOriginLabel = showOriginLabel
        self.labelSize = labelSize
    }
}
