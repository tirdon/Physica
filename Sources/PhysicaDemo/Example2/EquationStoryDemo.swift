// EquationStoryDemo — the four-slide scrollytelling demo for example2.html.
//
//  1. Setup   — a mass on a string (a global, always on the board) + a title.
//  2. Forces  — weight and tension arrows draw on; tapping the tension overlays
//               its x/y components, double-tapping clears.
//  3. Solve   — `.push(from: .right)` slides the vector law `\vec F = m\vec g +
//               \vec T` (an editable EquationEntity), draggable x/y projection
//               operators, and a target box in over the Forces board; an
//               EquationGame wins when the x-equation reaches its goal.
//  4. Period  — pans the camera to a fresh board and shows the small-angle
//               approximation: a `sin θ` graph that morphs straight to the line
//               `θ` (they coincide near zero), then the SHM period T = 2π√(ℓ/g).
//
// Narration captions (`story.caption`) run the whole way as a fixed subtitle band,
// decoupled from in-scene text — and double as the script when autoplaying (Space
// toggles autoplay in the web shell). Content is slide-scoped: each slide's own
// entities auto-clear when the *next* slide starts, while the pendulum globals
// (added before the slides) persist — so the last slide's board stays. No manual
// clears needed. Everything degrades: no font → no labels/captions/graph axes; no
// MathJax → stub/font token glyphs.

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
        story.background = .blackboard

        let bob = Position(1.2, 0.4, 0)

        // The pendulum is global scaffolding: `story.add`ed *before* the slides so
        // it stays on the board across all of them (Forces draws onto the mass;
        // Solve keeps it behind the equation). Globals are never in a slide's
        // own-introduced set, so the per-slide auto-clear leaves them untouched.
        let ceiling = Rectangle(width: 3.4, height: 0.2, color: .gray)
        ceiling.position = Position(0, 2.6, 0)
        let string = Line(start: Position(0, 2.5, 0), end: bob, width: 0.03, color: chalk)
        let mass = Circle(radius: 0.4, color: Color(hex: 0xE8C84A))
        mass.position = bob
        story.add(ceiling, string, mass)

        story.slide("Setup") { s in
            story.caption("A mass on a string — a pendulum at rest.")
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
        // The force arrows just draw on over the (global) mass/string — no
        // transition, no camera move. The camera stays at its default framing the
        // whole way through, so Solve's push-in content (below) slides in fully
        // on-screen rather than landing under a still-zoomed camera.
        story.slide("Forces") { s in
            story.caption("Two forces act on the bob: weight down, tension along the string — tap the tension to split it.")
            s.play(.draw(weight), for: 0.6.s)
            s.play(.draw(tension), for: 0.6.s)
            // weight & tension are Forces' own content → they stay visible under
            // Solve's slide-in and auto-clear once it lands.
        }

        // The tension arrow is the touch target: tap overlays its x/y components,
        // double-tap clears them. Both fire through the drag coordinator, which
        // stays live while the story rests paused. The handlers are stateless: the
        // reveal's in-flight draw and the arrows it introduces live on the scene,
        // owned by the handler's own entity — the coordinator supplies that owner,
        // so `interact`/`interrupt`/`hasInteraction` need no explicit owner. And
        // `interact` (not `play`) is what animates while the story rests paused — it
        // runs now, in parallel, outside the scrub history; a slide change clears
        // the reveal via `interruptAll`.
        tension.components[TapComponent.self] = TapComponent { current, _ in
            guard !current.hasInteraction() else { return }  // don't restack
            let cx = Arrow(start: bob, end: Position(0.2, bob.y, 0), color: opColor)
            let cy = Arrow(start: bob, end: Position(bob.x, 2.0, 0), color: opColor)
            current.interact(.draw(cx), .draw(cy), for: 0.6.s)
        }
        tension.components[DoubleTapComponent.self] = DoubleTapComponent { current, _ in
            current.interrupt()  // stop a running draw + remove cx/cy (owned by this entity)
        }

        let components = try? ComponentTable([
            "F": ("F_x", "0"),
            "g": ("0", "g"),
            "T": ("T\\cos\\theta", "T\\sin\\theta"),
        ])

        var game: EquationGame?
        story.slide("Solve", transition: .push(from: .right)) { s in
            story.caption("Resolve the vector law into components — drag a projection onto the equation.")
            // `.push(from: .right)`: the equation, operators, and target box slide
            // in from the right as one layer *over* the Forces board — its weight
            // and tension arrows stay visible underneath until the slide-in lands,
            // then auto-clear. The pendulum globals stay put behind everything.
            // The content is `s.add`ed at the slide's start so the push has it to
            // carry in (the slide-in adds it itself, ahead of these 0-duration
            // adds, so it is shown the whole way in).
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
                    scene: story.scene, equation: equation,
                    goal: try? Equation(parsing: "F_x = T\\cos\\theta"),
                    components: components, provider: provider
                )
            }
            // Solve's content auto-clears as the viewer crosses into Period below;
            // the pendulum globals stay.
        }

        // 4. Period — pan to a fresh board (the pendulum scrolls up out of frame)
        //    and show the small-angle approximation, then the SHM period. Camera
        //    moves are ordinary scrubbable clips, so scrolling back pans home.
        story.slide("Period") { s in
            story.caption("For small swings, the angle θ stays tiny.")
            s.play(s.frame.shift(Position(0, -3.6, 0)), for: 0.8.s)  // pan down to a clean board

            // Draw sin θ, then the straight line θ over it: the two hug near the
            // origin and peel apart at the edges — the small-angle law, shown side
            // by side rather than stated.
            let plane = Plane(
                x: -2.2...2.2, y: -1.6...1.6, gridStep: 1, size: SIMD2<Real>(6.4, 3.0), font: font
            )
            plane.position = Position(0, -3.6, 0)
            s.add(plane)
            let sine = plane.graph(of: { Real.sin($0) }, color: tensionColor, width: 0.035)
            s.play(.draw(sine), for: 1.s)
            story.caption("The straight line θ hugs sin θ near the origin, so sin θ ≈ θ.")
            // y = θ stays on the board only to x = ±1.6 (the y-edges); `graph`
            // would sample past that and clamp into a kinked shoulder, so plot the
            // clean diagonal corner-to-corner instead.
            let line = plane.plot(
                [SIMD2<Real>(-1.6, -1.6), SIMD2<Real>(1.6, 1.6)], color: opColor, width: 0.03
            )
            s.play(.draw(line), for: 1.s)

            // The period result lives in the narration band — the in-scene stroked
            // font has no √ / ℓ glyph, and the caption renders it cleanly.
            story.caption("So the bob is a simple harmonic oscillator, with period T = 2π√(ℓ ⁄ g).")
            // Last slide: no auto-clear fires, so the Period board persists.
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
