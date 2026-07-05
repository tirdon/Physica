// HamiltonianArticle — the actual Example3 article, authored with the DSL.
//
// Platform-neutral (pure value construction), so `swift build` on macOS builds
// and type-checks the whole thing; the WASI renderer and the host outline both
// consume this one `Document`. The subject is Physica's own physics core: the
// Hamiltonian / momentum-form rigid-body integrator described in CLAUDE.md.
// Every fact here is drawn from that spec — state is (transform, p, L), velocity
// is derived, integration is symplectic at a fixed 1/240 s, contacts are SDF
// surface samples, restitution combines as min(A, B) with a 0.4 default.
//
// Prose strings support a tiny inline markup the DOM renderer understands:
//   *italic*   **bold**   `code`   and inline math via MathJax \(…\) delimiters.
//
// The article DSL (Document/Chapter/math/procedure/…) now lives in the framework
// (PhysicaWeb, Sources/Physica/WASM/Article/), so this consumes it via
// `import Physica`.

import Physica

enum HamiltonianArticle {
    static let document = Document {
        Title(
            eyebrow: "Physics · Rigid bodies",
            "A rigid body, integrated the Hamiltonian way",
            subtitle: "How Physica advances a spinning, bouncing body by storing momentum instead of velocity — and why that makes the step both stable and deterministic.",
            byline: Byline(
                avatar: "PH",
                name: "Physica",
                meta: "8 min read · Hamiltonian mechanics · symplectic integration"
            ),
            abstract: "Most game physics stores a body's velocity and nudges it every frame. Physica stores its **momentum**. The distinction sounds pedantic, but it buys two concrete things: a *symplectic* update that does not pump energy into a long-running simulation, and a *fixed-step* integrator whose output is bit-for-bit reproducible across runs and platforms. This piece walks the state vector, the half-kick / drift / half-kick step, and the surface-sample contact model that ties them together.",
            stats: [
                Stat(value: "1/240 s", label: "fixed step"),
                Stat(value: "(q, p, L)", label: "state"),
                Stat(value: "0.4", label: "default restitution"),
                Stat(value: "4", label: "collider shapes"),
            ]
        )

        Chapter("The state you actually store", id: "state") {
            "A body's configuration is its *pose* — a position and an orientation — carried in one \\(4\\times4\\) transform. Its motion is carried not as a pair of velocities but as a pair of *momenta*: the linear momentum \\(\\mathbf{p}\\) and the angular momentum \\(\\mathbf{L}\\), the latter kept in world coordinates. So the full state is the triple \\((\\text{transform},\\ \\mathbf{p},\\ \\mathbf{L})\\), and nothing else needs to persist between frames."

            "Velocities are never stored — they are *derived* on demand. Linear velocity is momentum over mass; angular velocity is the world-frame angular momentum pushed through the inverse inertia, rotated into the body frame and back:"

            math(type: .equation, tag: "velocities") {
                "\\mathbf{v} = \\frac{\\mathbf{p}}{m}, \\qquad \\boldsymbol{\\omega} = R\\,I_{\\text{body}}^{-1}\\,R^{\\top}\\,\\mathbf{L}"
            }

            "Here \\(R\\) is the body's current rotation and \\(I_{\\text{body}}\\) its constant body-frame inertia tensor. Because \\(\\mathbf{L}\\) lives in the world frame, it is conserved under a free spin exactly — the tumbling of the classic Dzhanibekov intermediate-axis wobble falls straight out of **equation (1)** with no special casing."

            notation {
                Def("\\(\\text{transform}\\)", "the body's pose — position and orientation, one 4×4 matrix")
                Def("\\(\\mathbf{p} \\in \\mathbb{R}^{3}\\)", "linear momentum (world frame)")
                Def("\\(\\mathbf{L} \\in \\mathbb{R}^{3}\\)", "angular momentum (world frame) — the conserved quantity")
                Def("\\(I_{\\text{body}}\\)", "body-frame inertia tensor, constant for a rigid body")
                Def("\\(R,\\ R^{\\top}\\)", "rotation into / out of the body frame")
                Def("\\(H\\)", "the Hamiltonian — total energy as a function of pose and momenta")
            }

            headline("Why momentum, not velocity?")

            "Storing velocity forces you to remember how to update it, and every explicit velocity update leaks a little energy per step. Storing momentum lets the integrator work directly on the quantities the Hamiltonian is written in, so the update can be made *symplectic* — it preserves phase-space volume and keeps a discrete energy bounded for arbitrarily long runs. A stack of boxes settles and *stays* settled; it does not slowly jitter itself apart."

            "The Hamiltonian of a rigid body in a potential \\(U\\) is kinetic plus potential energy, written purely in the stored quantities:"

            math(type: .display) {
                "H(q, \\mathbf{p}, \\mathbf{L}) = \\frac{\\lVert\\mathbf{p}\\rVert^{2}}{2m} + \\tfrac{1}{2}\\,\\mathbf{L}^{\\top} R\\,I_{\\text{body}}^{-1} R^{\\top}\\,\\mathbf{L} + U(q)"
            }
        }

        Chapter("The symplectic step", id: "step") {
            "Physica advances the state with a **leapfrog** (velocity-Verlet) scheme: a half-step momentum kick from the forces, a full-step drift of the pose at the kicked momentum, then a second half-step kick from the forces at the new pose. Splitting the kick in two around the drift is what makes the composition symplectic and time-reversible."

            math(type: .equation, tag: "leapfrog") {
                "\\begin{aligned} \\mathbf{p}_{n+\\frac12} &= \\mathbf{p}_{n} - \\tfrac{h}{2}\\,\\nabla U(q_n), \\\\ q_{n+1} &= q_n + h\\,\\mathbf{p}_{n+\\frac12}/m, \\\\ \\mathbf{p}_{n+1} &= \\mathbf{p}_{n+\\frac12} - \\tfrac{h}{2}\\,\\nabla U(q_{n+1}) \\end{aligned}"
            }

            subheadline("A fixed step, drained by an accumulator")

            "The step size \\(h\\) is *not* the frame time. It is a fixed \\(1/240\\) of a second, held constant no matter how fast or slow the display runs. Each frame adds its real elapsed time to an accumulator, and the integrator drains that accumulator in whole \\(h\\)-sized chunks — running zero, one, or several fixed sub-steps per frame. A frame is never integrated with a variable \\(h\\), so the trajectory does not depend on the frame rate."

            "Because every sub-step is identical in size and the arithmetic is the same on every platform, the whole simulation is **deterministic**: `HamiltonianSystem.step(_:in:)` is exposed publicly precisely so a test can drive it by hand and assert an exact trajectory. Same initial state, same sequence of poses, every run."

            "Listed as an algorithm, one fixed sub-step is the three momentum lines of **equation (2)** wrapped in the orientation update:"

            procedure(
                name: "Procedure 1",
                title: "One fixed symplectic sub-step of step size \\(h = 1/240\\,\\text{s}\\)",
                input: "state \\((q_n,\\ \\mathbf{p}_n,\\ \\mathbf{L}_n)\\); forces \\(\\nabla U\\), torque \\(\\boldsymbol{\\tau}\\); step \\(h\\)",
                output: "advanced state \\((q_{n+1},\\ \\mathbf{p}_{n+1},\\ \\mathbf{L}_{n+1})\\)",
                foot: "The scalar \\(h\\) is folded into each kick; the drift uses the half-kicked momentum, which is what makes lines 1–5 a symplectic composition rather than plain forward Euler."
            ) {
                Step("\\(\\mathbf{p} \\gets \\mathbf{p}_n - \\tfrac{h}{2}\\,\\nabla U(q_n)\\)", note: "half-kick: linear momentum")
                Step("\\(\\mathbf{L} \\gets \\mathbf{L}_n - \\tfrac{h}{2}\\,\\boldsymbol{\\tau}(q_n)\\)", note: "half-kick: angular momentum")
                Step("\\(q_{n+1} \\gets q_n + h\\,\\mathbf{p}/m\\)", note: "drift the position at the kicked momentum")
                Step("advance orientation by \\(\\boldsymbol{\\omega} = R\\,I^{-1}R^{\\top}\\mathbf{L}\\) over \\(h\\)", note: "drift the pose")
                Step("\\(\\mathbf{p}_{n+1} \\gets \\mathbf{p} - \\tfrac{h}{2}\\,\\nabla U(q_{n+1})\\)", note: "second half-kick at the new pose")
                Step("\\(\\mathbf{L}_{n+1} \\gets \\mathbf{L} - \\tfrac{h}{2}\\,\\boldsymbol{\\tau}(q_{n+1})\\)")
                Return("\\((q_{n+1},\\ \\mathbf{p}_{n+1},\\ \\mathbf{L}_{n+1})\\)")
            }

            "A few constants recur across the step. They are folded into their consuming operations rather than stored as separate state:"

            table(columns: 2, separator: .row) {
                formula("h = \\tfrac{1}{240}\\,\\text{s}")
                "the fixed sub-step — small enough that even a fast spin resolves smoothly, and identical on every platform for reproducibility"
                formula("\\mathbf{v} = \\mathbf{p}/m")
                "linear velocity, recovered from momentum whenever a query or the drift needs it"
                formula("\\boldsymbol{\\omega} = R\\,I^{-1}R^{\\top}\\mathbf{L}")
                "angular velocity, recovered from the world-frame angular momentum each sub-step"
                formula("e = \\min(e_A,\\ e_B)")
                "the restitution used at a contact — the softer of the two bodies (see §3)"
            }
        }

        Chapter("Contacts and restitution", id: "contacts") {
            "Collisions are resolved from *surface samples* of a signed distance field. The same routine handles every collider — a sphere, a box, an ellipsoid, a torus — because each is just an SDF and the contact solver only ever asks it for the nearest surface point and its outward normal. There is no per-shape pair code: sphere-vs-torus and box-vs-ellipsoid go down exactly the same path."

            "When two bodies touch, the bounce is governed by a single coefficient of restitution, and Physica combines the two bodies' coefficients by taking the *minimum*:"

            math(type: .equation, tag: "restitution") {
                "e = \\min(e_A,\\ e_B), \\qquad e_{\\text{default}} = 0.4"
            }

            "The \\(\\min\\) rule means a bouncy ball dropped on a dead-soft floor does not bounce: the softer surface wins. It also has a sharp practical consequence — because the default coefficient is \\(0.4\\), a bounce test must set restitution explicitly on the *static* body too, or the static \\(0.4\\) silently clamps the result. Physics bodies are expected to be scene roots, so their contacts resolve in world space without a parent transform confusing the SDF query."

            headline("Freezing the far field")

            "A body that has drifted well outside the visible frame — past three times the camera's extent — is *frozen*: no integration, no contact tests, no cost. It thaws the moment it re-enters. Integration tests deliberately use a large explicit camera so nothing under test wanders into the freeze region mid-trajectory."

            presentation {
                slide(
                    "One integrator, four shapes",
                    caption: "Sphere, box, ellipsoid, torus — **one** contact solver. Each collider is a signed distance field; the solver only asks for the nearest surface point and its normal, so there is no combinatorial explosion of shape-pair code."
                ) { scene in
                    let accent = Color(hex: 0x4CC878)
                    let shapes = [
                        MeshEntity(mesh: .sphere(radius: 0.55), color: accent),
                        MeshEntity(mesh: .box(size: SIMD3(1, 1, 1)), color: accent),
                        MeshEntity(mesh: .ellipsoid(radii: SIMD3(0.75, 0.45, 0.45)), color: accent),
                        MeshEntity(mesh: .torus(majorRadius: 0.5, minorRadius: 0.2), color: accent),
                    ]
                    for (index, shape) in shapes.enumerated() {
                        shape.position = Position(Real(index * 2) - 3, -0.2, 0)
                        shape.scale = SIMD3(repeating: 0.001)
                    }
                    // The torus's hole is built facing +Y (lying flat); tip it onto its
                    // side so the ring faces the camera instead of showing edge-on.
                    shapes[3].orientation = Quaternion(angle: .pi / 2, axis: Position(1, 0, 0))
                    scene.add(shapes[0], shapes[1], shapes[2], shapes[3])
                    scene.play(
                        shapes[0].scale(to: 1), shapes[1].scale(to: 1),
                        shapes[2].scale(to: 1), shapes[3].scale(to: 1),
                        for: 0.7.s
                    )
                }
                slide("Deterministic by construction") {
                    "A fixed \\(1/240\\,\\text{s}\\) sub-step plus identical arithmetic every run means the trajectory is exactly reproducible. `HamiltonianSystem.step(_:in:)` is public so a test can drive it and assert pose-by-pose."
                }
                slide("Momentum keeps energy honest") {
                    "Storing \\((\\mathbf{p}, \\mathbf{L})\\) and updating them symplectically keeps discrete energy bounded over long runs. A settled stack stays settled; a free spin conserves \\(\\mathbf{L}\\) exactly and tumbles on its own."
                }
            }
        }

        Footer {
            "Physica · Hamiltonian rigid-body integrator · momentum-form walkthrough"
            "State (transform, p, L) · symplectic 1/240 s step · SDF surface-sample contacts · restitution min(A, B), default 0.4."
        }
    }
}
