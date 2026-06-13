// EquationStoryDemo — the three-slide scrollytelling demo for story.html.
//
//  1. Setup   — a mass on a string (drawn) + a title.
//  2. Forces  — camera pushes in; weight and tension arrows draw on; an action
//               button overlays the tension's components in parallel.
//  3. Solve   — the vector law `\vec F = m\vec g + \vec T` as an editable
//               EquationEntity, draggable x/y projection operators, and a target
//               box; an EquationGame wins when the x-equation reaches its goal.
//
// Everything degrades: no font → no labels; no MathJax → stub/font token glyphs.

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

        story.slide("Setup") { s in
            let ceiling = Rectangle(width: 3.4, height: 0.2, color: .gray)
            ceiling.position = Position(0, 2.6, 0)
            s.add(ceiling)
            let string = Line(start: Position(0, 2.5, 0), end: bob, width: 0.03, color: chalk)
            let mass = Circle(radius: 0.4, color: Color(hex: 0xE8C84A))
            mass.position = bob
            s.play(.draw(string), for: 0.6.s)
            s.play(.draw(mass), for: 0.6.s)
            if let font {
                let title = TextEntity("A mass on a string", font: font, fontSize: 0.5, color: chalk)
                title.position = Position(0, -2.6, 0)
                s.play(.write(title), for: 1.s)
            }
        }

        let weight = Arrow(start: bob, end: Position(bob.x, bob.y - 1.6, 0), color: weightColor)
        let tension = Arrow(start: bob, end: Position(0.2, 2.0, 0), color: tensionColor)
        story.slide("Forces") { s in
            s.play(s.frame.shift(Position(0.4, 0.2, 0)), s.frame.zoom(to: 7.5), for: 1.2.s)
            s.play(.draw(weight), for: 0.6.s)
            s.play(.draw(tension), for: 0.6.s)
        }
        story.action("Show components", id: "components") { s in
            let cx = Arrow(start: bob, end: Position(0.2, bob.y, 0), color: opColor)
            let cy = Arrow(start: bob, end: Position(bob.x, 2.0, 0), color: opColor)
            s.interact(.draw(cx), .draw(cy), for: 0.6.s)
        }

        let components = try? ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])

        var game: EquationGame?
        story.slide("Solve") { s in
            s.play(s.frame.shift(Position(-0.4, -0.2, 0)), s.frame.zoom(to: 10), for: 1.2.s)
            guard let law = try? Equation(parsing: "\\vec F = m\\vec g + \\vec T") else { return }
            let equation = EquationEntity(law, provider: provider, style: EquationStyle(fontSize: 0.8, color: chalk))
            equation.position = Position(0, 1.6, 0)
            s.add(equation)

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
