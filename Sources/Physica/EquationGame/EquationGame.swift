// EquationGame — wires an EquationEntity's drag-and-drop into algebra moves.
//
// The game is the glue between the drag layer and the move engine: it installs
// one drop target on the equation that reads what was dropped and applies the
// matching move. Tokens dragged out of the editable row carry their address (on
// the proxy's TokenComponent) and run the cross-'=' inverse moves; an external
// expression literal multiplies both sides (and surfaces choice chips when that
// is ambiguous); a projection operator spawns a new scalar EquationEntity. A
// resolved move appends a row; reaching the goal highlights and fires `onWin`.

import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel

@MainActor
public final class EquationGame {
    public let scene: Scene
    public let equation: EquationEntity
    public var goal: Equation?
    public let components: ComponentTable?
    public let provider: TokenGlyphProvider

    public var onWin: (@MainActor () -> Void)?
    public var onMove: (@MainActor (Equation) -> Void)?
    public var onProjection: (@MainActor (ProjectionAxis, EquationEntity) -> Void)?
    public private(set) var hasWon = false
    public private(set) var spawnedEquations: [EquationEntity] = []
    public private(set) var chipEntities: [Entity] = []

    private let accent = Color(hex: 0x53F0FF)

    public init(
        scene: Scene,
        equation: EquationEntity,
        goal: Equation? = nil,
        components: ComponentTable? = nil,
        provider: TokenGlyphProvider
    ) {
        self.scene = scene
        self.equation = equation
        self.goal = goal
        self.components = components
        self.provider = provider
        installDropTarget()
    }

    private func installDropTarget() {
        equation.components[DropTargetComponent.self] = DropTargetComponent(
            accepts: { payload in
                switch payload {
                case .expression, .projection: return true
                case .tag: return false
                }
            },
            onDrop: { [weak self] payload, dragged in
                self?.handleDrop(payload, dragged: dragged) ?? .rejected
            }
        )
    }

    // MARK: Drop routing

    private func handleDrop(_ payload: DragPayload, dragged: Entity) -> DropResolution {
        switch payload {
        case .expression(let expression):
            if let address = dragged.components[TokenComponent.self]?.token.address {
                return moveToken(at: address, dragged: dragged)  // a token dragged out of the row
            }
            return applyExternal(expression, dragged: dragged)   // an external multiplier literal
        case .projection(let axis):
            return project(onto: axis, dragged: dragged)
        case .tag:
            return .rejected
        }
    }

    private func moveToken(at address: TokenAddress, dragged: Entity) -> DropResolution {
        let side: EquationSide = dragged.worldBounds.center.x < equalsWorldX ? .lhs : .rhs
        return resolve(equation.current.movingTerm(at: address, to: side), dragged: dragged)
    }

    private func applyExternal(_ expression: Expression, dragged: Entity) -> DropResolution {
        let side: EquationSide = dragged.worldBounds.center.x < equalsWorldX ? .lhs : .rhs
        return resolve(equation.current.applying(expression, asRole: .factor, to: side), dragged: dragged)
    }

    private func project(onto axis: ProjectionAxis, dragged: Entity) -> DropResolution {
        guard let components else { return .rejected }
        do {
            let projected = try equation.current.projected(onto: axis, components: components)
            scene.retire(dragged)  // the operator is one-shot — gone for good, even across scrubs
            let spawned = EquationEntity(projected, provider: provider, style: equation.style)
            spawnedEquations.append(spawned)
            scene.insert(spawned)
            realignSpawnedEquations()
            onProjection?(axis, spawned)
            return .accepted
        } catch {
            return .rejected
        }
    }

    /// Stacks every projected equation in a column beneath the source equation
    /// so a second operator's result lands below the first instead of on top of
    /// it (each spawn would otherwise key off the same `equation.position`).
    private func realignSpawnedEquations() {
        let step = equation.worldBounds.size.y + 1
        for (index, spawned) in spawnedEquations.enumerated() {
            spawned.position = Position(
                equation.position.x,
                equation.position.y - step * Real(index + 1),
                equation.position.z
            )
        }
    }

    private func resolve(_ outcome: MoveOutcome, dragged: Entity) -> DropResolution {
        switch outcome {
        case .resolved(let next):
            consume(dragged)
            commit(next)
            return .accepted
        case .choice(let choices):
            consume(dragged)
            present(choices)
            return .accepted
        case .rejected:
            return .rejected  // coordinator shakes the equation and snaps the ghost home
        }
    }

    private func commit(_ next: Equation) {
        equation.appendRow(next)
        onMove?(next)
        checkWin()
    }

    private func checkWin() {
        guard !hasWon, let goal, equation.current.matches(goal) else { return }
        hasWon = true
        scene.interact(.highlight(equation, color: accent))
        onWin?()
    }

    /// Pulse the current equation as a nudge.
    public func showHint() {
        scene.interact(.highlight(equation, color: accent))
    }

    // MARK: Choice chips

    private func present(_ choices: [AlgebraChoice<Equation>]) {
        dismissChoice()
        scene.drag.isEnabled = false  // can't drag anything else until the choice resolves
        let height: Real = 0.9
        let baseY = equation.position.y - (equation.worldBounds.size.y / 2) - 1
        for (index, choice) in choices.enumerated() {
            let chip = makeChip(label: choice.label) { [weak self] in self?.commitChoice(choice.value) }
            chip.position = Position(0, baseY - Real(index) * (height + 0.3), 0)
            chipEntities.append(chip)
            scene.insert(chip)  // transient UI — last root → painter's top, not scrub history
        }
    }

    private func commitChoice(_ chosen: Equation) {
        dismissChoice()
        commit(chosen)
    }

    /// Removes the pending choice chips and re-enables dragging.
    public func dismissChoice() {
        for chip in chipEntities { scene.detach(chip) }
        chipEntities.removeAll()
        scene.drag.isEnabled = true
    }

    private func makeChip(label: String, onTap: @escaping @MainActor () -> Void) -> Entity {
        let chip = Group()
        chip.name = "chip"
        let run = provider.glyphs(for: DisplayToken(kind: .variable, value: label, tex: label))
        let text = TextEntity(glyphs: run.glyphs, fontSize: 0.5)
        text.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: accent, strokeColor: accent, strokeWidth: 0.012, isFilled: true
        )
        text.shown()
        let width = Swift.max(run.width * 0.5 + 0.5, 1.2)
        let border = PathEntity()
        border.path = Path.roundedRect(width: width, height: 0.9, cornerRadius: 0.2)
        border.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: accent, strokeColor: accent, strokeWidth: 0.03, isFilled: false
        )
        chip.addChild(border)
        chip.addChild(text)
        chip.components[TapComponent.self] = TapComponent { _ in onTap() }
        return chip
    }

    // MARK: Helpers

    /// World x of the editable row's '=' — the side a drop lands on is decided
    /// by which side of this line it falls.
    private var equalsWorldX: Real {
        equation.editableRow?.equalsEntity?.worldBounds.center.x ?? equation.worldBounds.center.x
    }

    /// Removes a consumed drag ghost. Row-token proxies and external literals are
    /// scene roots (no parent); never detach a real token still living in a row.
    private func consume(_ dragged: Entity) {
        if dragged.parent == nil { scene.detach(dragged) }
    }
}
