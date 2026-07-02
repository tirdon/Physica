// PlaceholderEquationEntity — an empty "text box" that accepts a dropped
// expression and (optionally) checks it against a target answer.
//
// A rounded-rect border with an optional hint, plus a DropTargetComponent. A
// drop whose expression matches `target` (via the simplifier — `2x` matches
// `x·2`) snaps in and highlights; a mismatch is rejected, so the coordinator
// shakes the box and snaps the literal back. `target == nil` accepts anything.

import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class PlaceholderEquationEntity: Group {
    public var target: Expression?
    public var onFill: (@MainActor (_ dropped: Expression, _ isMatch: Bool) -> Void)?
    public private(set) var content: Expression?
    public var isFilled: Bool { content != nil }

    private let border: PathEntity
    private let accent: Color
    private let baseStrokeWidth: Real = 0.03

    public init(
        width: Real = 2.4,
        height: Real = 1.2,
        hint: String? = nil,
        font: Font? = nil,
        target: Expression? = nil,
        color: Color = Color(hex: 0x53F0FF)
    ) {
        self.target = target
        self.accent = color
        border = PathEntity()
        border.name = "placeholder-border"
        border.path = Path.roundedRect(
            width: width, height: height,
            cornerRadius: Swift.min(0.3, Swift.min(width, height) * 0.3)
        )
        border.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color, strokeColor: color, strokeWidth: baseStrokeWidth, isFilled: false
        )
        super.init()
        name = "placeholder"
        addChild(border)
        if let hint, let font {
            let label = TextEntity(hint, font: font, fontSize: Swift.min(0.4, height * 0.4), color: color)
            label.shown()
            label.name = "placeholder-hint"
            addChild(label)
        }
        components[DropTargetComponent.self] = DropTargetComponent(
            accepts: { payload in
                if case .expression = payload { return true }
                return false
            },
            onDrop: { [weak self] payload, dragged in
                self?.handleDrop(payload, dragged: dragged) ?? .rejected
            },
            onHoverChanged: { [weak self] hovering in
                self?.setHighlighted(hovering)
            }
        )
    }

    private func handleDrop(_ payload: DragPayload, dragged: Entity) -> DropResolution {
        guard case .expression(let expression) = payload else { return .rejected }
        let isMatch = target.map { expression.matches($0) } ?? true
        if isMatch {
            content = expression
            if let scene {
                scene.interact(dragged.move(to: center), for: 0.2.s)
                scene.interact(.highlight(self, color: accent))
            }
            onFill?(expression, true)
            return .accepted
        }
        onFill?(expression, false)
        return .rejected  // the coordinator shakes us and snaps the literal home
    }

    private func setHighlighted(_ on: Bool) {
        var renderStyle = border.components[RenderStyleComponent.self] ?? RenderStyleComponent()
        renderStyle.strokeWidth = on ? baseStrokeWidth * 1.6 : baseStrokeWidth
        border.components[RenderStyleComponent.self] = renderStyle
    }
}
