// HamiltonianArticle — the article AppExample1 serializes. Authored on the same
// `Document` DSL the wasm Example3 uses (Title / Chapter / math / notation /
// procedure / table / presentation / Footer), fed to the native `ArticleHTML`
// serializer instead of the browser DOM. Everything renders standalone —
// including the live `presentation {}` deck: natively it has no WebGPU canvas, so
// `PhysicaDocument.run()` floats a real Metal view over its slot and
// `write(to:)` bakes it to an embedded `<video>` (see `PhysicaDocument`). It
// stays off images, which still need the web edition.

#if os(macOS)
import PhysicaApp

enum HamiltonianArticle {
    /// Deck palette (dark stage): chalk text, an accent green.
    private static let chalk = Color(hex: 0xF2F2EC)
    private static let accent = Color(hex: 0x4CC878)

    static var document: PhysicaDocument {
        PhysicaDocument("Physics · Rigid bodies", background: .documentDark) {
            Title(
                eyebrow: "Symplectic integration",
                "A rigid body, integrated the Hamiltonian way",
                subtitle: "How Physica advances a spinning, bouncing body by storing momentum instead of velocity — and why that makes the step both stable and deterministic.",
                byline: Byline(
                    avatar: "PH",
                    name: "Physica",
                    meta: "8 min read · Hamiltonian mechanics · symplectic integration"
                ),
                abstract: "Most game physics stores a body's *velocity* and nudges it every frame. Physica stores its **momentum** \\(p = m v\\). The distinction buys two concrete things: a *symplectic* update that does not pump energy into a long-running simulation, and a *fixed-step* integrator whose output is bit-for-bit reproducible across runs and platforms.",
                stats: [
                    Stat(value: "1/240 s", label: "fixed step"),
                    Stat(value: "(q, p, L)", label: "state"),
                    Stat(value: "0.4", label: "default restitution"),
                    Stat(value: "4", label: "collider shapes"),
                ]
            )

            Chapter("The state you store", id: "state") {
                "A body carries its position \\(q\\), its linear momentum \\(p\\), and its angular momentum \\(L\\). Linear and angular *velocities* are never stored — they are derived from the momenta and the current orientation, so a scrub or a concurrent animation can hand the body over mid-motion without drift:"
                math(type: .equation) { "\\omega = R\\,I^{-1} R^{\\top} L" }
                "Here \\(R\\) is the body's rotation and \\(I\\) its body-frame inertia tensor. Storing \\(L\\) rather than \\(\\omega\\) is what keeps the spin stable as the orientation turns."
                notation {
                    Def("\\(H\\)", "the Hamiltonian — the body's total energy")
                    Def("\\(I\\)", "the body-frame inertia tensor (constant)")
                    Def("\\(R\\)", "the world-from-body rotation")
                    Def("\\(\\nabla U\\)", "the potential gradient — the force")
                }
            }

            Chapter("The symplectic step", id: "step") {
                "Each frame advances the state by a **half-kick / drift / half-kick** (velocity Verlet) at a fixed \\(1/240\\,\\mathrm{s}\\) step, accumulated so the render frame rate never leaks into the physics:"
                procedure(
                    name: "Procedure 1",
                    title: "One symplectic step of size \\(h\\)",
                    input: "state \\((q, p, L)\\)",
                    output: "the advanced state",
                    foot: "The kick is split around the drift so the update is time-reversible — the source of the energy stability."
                ) {
                    Step("\\(p \\gets p - \\tfrac{h}{2}\\,\\nabla U(q)\\)", note: "half-kick")
                    Step("\\(q \\gets q + h\\,M^{-1} p\\)", note: "drift")
                    Step("\\(L \\gets L + \\tfrac{h}{2}\\,\\tau\\)", note: "angular half-kick")
                    Return("the updated \\((q, p, L)\\)")
                }
                "Because the map is time-reversible, the discrete energy oscillates around the true value instead of drifting away from it:"
                math(type: .equation) { "H(q, p) = \\tfrac{1}{2}\\,p^{\\top} M^{-1} p + U(q)" }
            }

            Chapter("Contacts", id: "contacts") {
                "Collisions are resolved from surface samples, uniform across every collider shape. Restitution is the *minimum* of the two bodies', so a lively ball needs a lively floor:"
                table(columns: 2, separator: .row) {
                    formula("\\Delta t = 1/240\\,\\mathrm{s}"); "fixed integration step"
                    formula("e = \\min(e_A, e_B)"); "pairwise restitution"
                    formula("e = 0.4"); "default restitution"
                    "sphere · box · ellipsoid · torus"; "the four collider shapes"
                }
            }

            Chapter("See it move", id: "deck") {
                "The same ideas, animated. Natively this deck is a live Metal view floated over the article (drag the arrows to step it); the written `.html` bakes it to a short embedded video."
                presentation {
                    slide(
                        "Momentum is the state",
                        caption: "Physica stores \\(p = m v\\) — the body's momentum — not its velocity."
                    ) { s in
                        let body = Circle(radius: 0.72, color: Color(hex: 0x2B6CFF)).stroke(.white, width: 0.03)
                        body.position = Position(-2.1, 0, 0)
                        s.play(.draw(body), for: 0.8.s)
                        let arrow = Line(
                            start: Position(-2.1, 0, 0), end: Position(1.5, 0, 0),
                            width: 0.06, color: accent
                        )
                        s.play(.draw(arrow), for: 0.6.s)
                        let label = TextEntity("p = m v", fontSize: 0.6, color: chalk)
                        label.position = Position(-0.3, 1.05, 0)
                        s.play(.write(label), for: 0.8.s)
                        s.wait(0.4.s)
                    }

                    slide(
                        "Energy doesn't drift",
                        caption: "A symplectic step keeps the discrete energy bounded — it oscillates instead of climbing away."
                    ) { s in
                        let font = FontBook.resolve(.body).font
                        let plane = Plane(x: 0...6, y: -1...1, gridStep: 1, font: font).size(6.2, aspect: 2.6)
                        plane.position = Position(0, -0.1, 0)
                        s.add(plane)
                        s.play(.draw(plane.grid), .draw(plane.xAxis), .draw(plane.yAxis), for: 0.8.s)
                        let symplectic = plane.graph(of: { x in 0.28 * Real.sin(3 * x) }, color: accent)
                        let drifting = plane.graph(of: { x in 0.11 * x - 0.32 }, color: .orange)
                        s.play(.draw(symplectic), for: 0.9.s)
                        s.play(.draw(drifting), for: 0.9.s)
                        s.wait(0.4.s)
                    }

                    slide(
                        "Contacts bounce",
                        caption: "Restitution is \\(\\min(e_A, e_B)\\): a lively ball needs a lively floor."
                    ) { s in
                        let floor = Line(
                            start: Position(-3, -1.9, 0), end: Position(3, -1.9, 0),
                            width: 0.09, color: chalk
                        )
                        s.play(.draw(floor), for: 0.5.s)
                        let ball = Circle(radius: 0.42, color: .red).stroke(.white, width: 0.03)
                        ball.position = Position(0, 2.0, 0)
                        s.play(.draw(ball), for: 0.4.s)
                        s.play(ball.move(to: Position(0, -1.44, 0)), for: 0.5.s, easing: .easeIn)
                        s.play(ball.move(to: Position(0, 0.9, 0)), for: 0.5.s, easing: .easeOut)
                        s.play(ball.move(to: Position(0, -1.44, 0)), for: 0.45.s, easing: .easeIn)
                        s.play(.highlight(ball), for: 1.0.s)
                    }
                }
            }

            Footer {
                "Physica · rigid-body integrator"
                "Rendered by **ArticleHTML** — a single self-contained HTML file, no wasm."
            }
        }
    }
}
#endif
