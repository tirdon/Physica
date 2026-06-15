// EquationStoryDemo — the three-slide scrollytelling demo for story.html.
//
//  1. Setup   — a mass on a string (a global, always on the board) + a title.
//  2. Forces  — camera pushes in; weight and tension arrows draw on; tapping
//               the tension overlays its x/y components, double-tapping clears.
//  3. Solve   — the vector law `\vec F = m\vec g + \vec T` as an editable
//               EquationEntity, draggable x/y projection operators, and a target
//               box; an EquationGame wins when the x-equation reaches its goal.
//
// Content is slide-scoped: each slide's own entities auto-clear when the *next*
// slide starts, while the pendulum globals (added before the slides) persist — so
// the last slide's board stays. No manual clears needed. Everything degrades: no
// font → no labels; no MathJax → stub/font token glyphs.

#if os(WASI)
import Physica

@MainActor
enum EquationStoryDemo {
    private static let chalk = Color(hex: 0xF2F2EC)
    private static let tensionColor = Color(hex: 0x53F0FF)
    private static let weightColor = Color(hex: 0xFF6B6B)
    private static let opColor = Color(hex: 0x8BE0A4)

    /// Builds the slides on `story` and returns the equation game (the caller
    /// retains it so its drop handling stays alive).
    @discardableResult
    static func build(_ story: Story, font: Font?, provider: TokenGlyphProvider) -> EquationGame? {
        let scene = story.scene
        scene.background = .blackboard

        let bob = Position(1.2, 0.4, 0)

        // The pendulum is global scaffolding: `scene.add`ed *before* the slides so
        // it stays on the board across all of them (Forces draws onto the mass;
        // Solve keeps it behind the equation). Globals are never in a slide's
        // own-introduced set, so the per-slide auto-clear leaves them untouched.
        let ceiling = Rectangle(width: 3.4, height: 0.2, color: .gray)
        ceiling.position = Position(0, 2.6, 0)
        let string = Line(start: Position(0, 2.5, 0), end: bob, width: 0.03, color: chalk)
        let mass = Circle(radius: 0.4, color: Color(hex: 0xE8C84A))
        mass.position = bob
        scene.add(ceiling, string, mass)

        story.slide("Setup") { s in
            if let font {
                let title = TextEntity("A mass on a string", font: font, fontSize: 0.42, color: chalk)
                title.position = Position(0, -2.6, 0)
                s.play(.write(title), for: 1.s)
                // A callout annotation naming the bob (label + leader arrow).
                let note = Callout(
                    "the bob", pointingAt: mass, font: font,
                    edge: .topRight, distance: 1.3, fontSize: 0.34, color: chalk
                )
                s.add(note)
            }
            // No clear needed: the title and callout are Setup's own content, so
            // they auto-clear as the viewer crosses into Forces; globals stay.
        }

        let weight = Arrow(start: bob, end: Position(bob.x, bob.y - 1.6, 0), color: weightColor)
        let tension = Arrow(start: bob, end: Position(0.2, 2.0, 0), color: tensionColor)
        story.slide("Forces", transition: .push(from: .right)) { s in
            s.play(s.frame.shift(Position(0.4, 0.2, 0)), s.frame.zoom(to: 7.5), for: 1.2.s)
            s.play(.draw(weight), for: 0.6.s)
            s.play(.draw(tension), for: 0.6.s)
            // weight & tension are Forces' own content → auto-clear into Solve.
        }

        // The tension arrow is the touch target: a tap overlays its x/y
        // components, a double-tap clears them. Both fire through the drag
        // coordinator, which stays live while the story rests paused. The
        // components draw via an `interact` (parallel, outside the scrub history);
        // keep references so a double-tap can remove them and a re-tap can't
        // stack duplicates.
        var componentArrows: [Entity] = []
        var drawHandle: InteractionRunner.Handle?
        let clearComponents = {
            // Stop the reveal first: `.draw` re-inserts its target every frame
            // (introducesTarget), so a `scene.remove` while it's mid-flight is
            // undone on the next advance — which is exactly what a double-tap hits
            // (tap shows → dblclick clears, all within the draw's 0.6 s). interrupt()
            // drops the interaction from the active set, then the remove sticks.
            if let handle = drawHandle {
                scene.interactions.interrupt(handle, in: scene)
                drawHandle = nil
            }
            for arrow in componentArrows { scene.remove(arrow) }
            componentArrows.removeAll()
        }
        let showComponents = {
            guard componentArrows.isEmpty else { return }  // already up — don't restack
            let cx = Arrow(start: bob, end: Position(0.2, bob.y, 0), color: opColor)
            let cy = Arrow(start: bob, end: Position(bob.x, 2.0, 0), color: opColor)
            componentArrows = [cx, cy]
            drawHandle = scene.interact(.draw(cx), .draw(cy), for: 0.6.s)
        }
        tension.components[TapComponent.self] = TapComponent { _ in showComponents() }
        tension.components[DoubleTapComponent.self] = DoubleTapComponent { _ in clearComponents() }

        let components = try? ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])

        var game: EquationGame?
        story.slide("Solve") { s in
            // Forces' arrows auto-cleared as we arrived here; the pendulum globals
            // stay. Add the equation, operators, and
            // target box at the slide's *start* (before the camera clip) so they're
            // present the instant you arrive: a right-arrow step lands on the
            // slide's first boundary, and adds tucked after the camera clip would
            // only appear a full tween later.
            if let law = try? Equation(parsing: "\\vec F = m\\vec g + \\vec T") {
                let equation = EquationEntity(
                    law, provider: provider,
                    style: EquationStyle(fontSize: 0.55, color: chalk, rowSpacing: 0.3)
                )
                equation.position = Position(0, 1.6, 0)
                s.add(equation)

                // Operators are one-shot: dropping one on the equation makes the
                // game retire it, so a scrub up-and-back-down won't bring it back.
                let xOp = projectionOperator(.x, font: font)
                xOp.position = Position(-3.6, -0.6, 0)
                let yOp = projectionOperator(.y, font: font)
                yOp.position = Position(-3.6, -1.8, 0)
                s.add(xOp, yOp)

                let box = PlaceholderEquationEntity(
                    width: 2.6, height: 1.2,
                    hint: font == nil ? nil : "drop here", font: font,
                    target: try? Expression(parsing: "T\\cos\\theta")
                )
                box.position = Position(3.0, -1.6, 0)
                s.add(box)

                game = EquationGame(
                    scene: scene, equation: equation,
                    goal: try? Equation(parsing: "F_x = T\\cos\\theta"),
                    components: components, provider: provider
                )
            }
            // Camera home: undo the Forces push-in (shift 0.4,0.2 + zoom 7.5) in
            // one call instead of hand-rolling the inverse shift/zoom.
            s.reset(for: 1.2.s)
            // Last slide: no auto-clear fires, so the equation board persists.
        }
        return game
    }

    /// A draggable operator chip carrying a `.projection(axis)` payload.
    private static func projectionOperator(_ axis: ProjectionAxis, font: Font?) -> Entity {
        let chip = Group()
        chip.name = "project-\(axis.label)"
        let border = PathEntity()
        border.path = Path.roundedRect(width: 1.3, height: 0.9, cornerRadius: 0.2)
        border.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: opColor, strokeColor: opColor, strokeWidth: 0.03, isFilled: false
        )
        chip.addChild(border)
        if let font {
            let label = TextEntity("proj \(axis.label)", font: font, fontSize: 0.3, color: opColor)
            label.shown()
            chip.addChild(label)
        }
        chip.components[DraggableComponent.self] = DraggableComponent(payload: .projection(axis))
        return chip
    }
}
#endif
