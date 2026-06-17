// WaveStory — a five-slide scrollytelling explainer built from the paper
// "Finite Difference Solvers for Wave Interference". It is the story-mode twin of
// the demo's EquationStoryDemo: ONE scrubbable timeline partitioned into slides,
// narrated by `story.caption`, every step a navigable beat (scroll, or ↑/↓/←/→).
//
//   1. Title        — the wave equation as a travelling-wave motif.
//   2. The string   — the 1-D wave equation u_tt = c² u_xx on a fixed-end string,
//                     plotted as a standing wave that swings.
//   3. The grid     — centered finite differences → the explicit update stencil
//                     and the Courant stability bound r ≤ 1.
//   4. Two-D        — the damped 2-D wave, its five-point Laplacian stencil, and
//                     the r ≤ 1/√2 bound.
//   5. Interference — the climax: a plane wave through a two-hole barrier, ripples
//                     from each opening superposing into constructive/destructive
//                     fringes (the paper's Figure 1).
//
// This file is platform-neutral: it touches only the dependency-free core (Story,
// Plane, shapes, math TextEntities), so `swift build` type-checks it on the host
// even though the Example0 executable only *runs* under WASI. The MathJax formulas
// are rendered in the WASI entry point (Example0.swift) and handed in as optional
// TextEntities; everything degrades gracefully — without a font the labels drop,
// without MathJax the formulas drop, but the geometry always draws and the
// captions always narrate.

import Physica

@MainActor
enum WaveStory {
    // Chalkboard palette.
    static let chalk = Color(hex: 0xF2F2EC)   // prose / titles
    static let dim = Color(hex: 0x9FB0A6)     // muted prose / past state
    static let wave = Color(hex: 0x5CD0B3)    // teal — the wave / string
    static let accent = Color(hex: 0x53F0FF)  // cyan — ripples & dependency arrows
    static let warm = Color(hex: 0xFFD479)    // gold — the unknown / constructive
    static let cool = Color(hex: 0x8BE0A4)    // green — neighbour nodes
    static let danger = Color(hex: 0xFF6B6B)  // red — destructive

    /// MathJax formulas, pre-rendered in the WASI entry point (each `nil` when
    /// MathJax is unavailable — the slide then leans on its caption alone).
    struct Formulas {
        var wave1D: TextEntity?       // u_tt = c² u_xx
        var update1D: TextEntity?     // u_i^{n+1} = 2u_i^n − u_i^{n-1} + r²(…)
        var courant1D: TextEntity?    // r = cΔt/Δx ≤ 1
        var wave2D: TextEntity?       // u_tt = c²(u_xx+u_yy) − γu_t
        var courant2D: TextEntity?    // r ≤ 1/√2
        var constructive: TextEntity? // r₂ − r₁ = mλ
        var destructive: TextEntity?  // r₂ − r₁ = (m + ½)λ

        init() {}
    }

    static func build(_ story: Story, font: Font?, formulas: Formulas) {
        story.background = .blackboard

        titleSlide(story, font: font)
        stringSlide(story, font: font, formulas: formulas)
        gridSlide(story, font: font, formulas: formulas)
        twoDSlide(story, font: font, formulas: formulas)
        interferenceSlide(story, font: font, formulas: formulas)
    }

    // MARK: - 1. Title

    private static func titleSlide(_ story: Story, font: Font?) {
        story.slide("Title") { s in
            story.caption("We solve the wave equation on a grid — marching it forward in time, one step at a time.")

            if let font {
                // Plain (un-shown) text entities — `.write` reveals them.
                let line1 = made("Finite Difference Solvers", font, at: pt(0, 1.7), size: 0.58, color: chalk)
                let line2 = made("for Wave Interference", font, at: pt(0, 0.95), size: 0.58, color: chalk)
                s.play(.write(line1), .write(line2), for: 1.4.s)

                let subtitle = made(
                    "from a vibrating string to the double slit",
                    font, at: pt(0, 0.2), size: 0.32, color: dim
                )
                s.play(.write(subtitle), for: 0.9.s)
            }

            // A travelling wave strokes itself across the lower board (kept above
            // the caption band).
            let motif = curve(
                sineSamples(amplitude: 0.5, cycles: 2.5, x0: -4.2, x1: 4.2, baseline: -1.25, count: 140),
                color: wave, width: 0.06
            )
            s.play(.draw(motif), for: 1.3.s)
        }
    }

    // MARK: - 2. The vibrating string (1-D wave equation)

    private static func stringSlide(_ story: Story, font: Font?, formulas: Formulas) {
        story.slide("The string") { s in
            story.caption("One dimension first: a string fixed at both ends, plucked into a half-sine.")
            write(formulas.wave1D, at: pt(0, 2.5), on: s, for: 1.s)

            let L: Real = 4
            let plane = Plane(
                x: 0...L, y: -1.5...1.5, gridStep: 1, subdivisions: 2,
                size: SIMD2<Real>(7.2, 2.7), font: font
            )
            plane.position = pt(0, -0.4)
            s.add(plane)

            // Initial shape f(x) = sin(πx/L) — the fundamental mode.
            let mode: (Real) -> Real = { Real.sin(Real.pi * $0 / L) }
            let string = plane.graph(of: mode, samples: 120, color: wave, width: 0.05)
            s.play(.draw(string), for: 1.1.s)

            // Pin the fixed ends u(0,t) = u(L,t) = 0.
            let left = node(at: plane.point(0, 0), radius: 0.1, color: chalk)
            let right = node(at: plane.point(L, 0), radius: 0.1, color: chalk)
            s.add(left, right)

            story.caption("Its ends stay pinned — u(0,\u{00A0}t) = u(L,\u{00A0}t) = 0 — so it rings like a guitar string.")
            // The standing wave swings: full amplitude → inverted → back.
            s.play(string.plot { -mode($0) }, for: 0.9.s)
            s.play(string.plot { mode($0) }, for: 0.9.s)
        }
    }

    // MARK: - 3. Discretize: the grid & the update stencil

    private static func gridSlide(_ story: Story, font: Font?, formulas: Formulas) {
        story.slide("The grid") { s in
            story.caption("Chop space and time into a grid. Each new value is built from its neighbours and its own past.")
            write(formulas.update1D, at: pt(0, 2.5), on: s, for: 1.4.s)

            // Time-vertical stencil: the unknown u_i^{n+1} (gold, top) depends on
            // the three level-n neighbours and the past level u_i^{n-1}. Kept above
            // the caption band (y ≳ -1.8) so nothing hides behind the narration.
            let cx: Real = 0.3
            let yNew: Real = 1.55, yMid: Real = 0.2, yPast: Real = -1.1
            let newNode = node(at: pt(cx, yNew), radius: 0.22, color: warm)
            let west = node(at: pt(cx - 1.8, yMid), radius: 0.18, color: cool)
            let here = node(at: pt(cx, yMid), radius: 0.18, color: cool)
            let east = node(at: pt(cx + 1.8, yMid), radius: 0.18, color: cool)
            let past = node(at: pt(cx, yPast), radius: 0.18, color: dim)
            s.add(west, here, east, past, newNode)

            if let font {
                s.add(
                    text("n+1", font, at: pt(-3.4, yNew), size: 0.3, color: dim),
                    text("n", font, at: pt(-3.4, yMid), size: 0.3, color: dim),
                    text("n-1", font, at: pt(-3.4, yPast), size: 0.3, color: dim)
                )
            }

            // Dependency arrows converging on the unknown.
            let aW = dependency(from: pt(cx - 1.8, yMid), to: pt(cx, yNew), color: accent)
            let aH = dependency(from: pt(cx, yMid), to: pt(cx, yNew), color: accent)
            let aE = dependency(from: pt(cx + 1.8, yMid), to: pt(cx, yNew), color: accent)
            let aP = dependency(from: pt(cx, yPast), to: pt(cx, yNew), color: warm)
            s.play(.draw(aW), .draw(aH), .draw(aE), .draw(aP), for: 1.s)
            s.play(.highlight(newNode, color: warm, padding: 0.22), for: 1.s)

            story.caption("Stable only when information can't outrun the grid — the Courant number r ≤ 1.")
            write(formulas.courant1D, at: pt(0, -1.75), on: s, for: 0.9.s)
            highlight(formulas.courant1D, color: accent, on: s)
        }
    }

    // MARK: - 4. Two dimensions + damping

    private static func twoDSlide(_ story: Story, font: Font?, formulas: Formulas) {
        story.slide("Two dimensions") { s in
            story.caption("In two dimensions the Laplacian becomes a five-point stencil, and a damping term γ bleeds energy away each step.")
            write(formulas.wave2D, at: pt(0, 2.5), on: s, for: 1.3.s)

            // Spatial five-point stencil: centre (gold) wired to four neighbours,
            // raised so the south node clears the caption band.
            let center = pt(0, 0.1)
            let east = pt(1.8, 0.1), west = pt(-1.8, 0.1)
            let north = pt(0, 1.5), south = pt(0, -1.3)
            let nodes = [
                node(at: east, radius: 0.18, color: cool),
                node(at: west, radius: 0.18, color: cool),
                node(at: north, radius: 0.18, color: cool),
                node(at: south, radius: 0.18, color: cool),
            ]
            let hub = node(at: center, radius: 0.24, color: warm)
            s.add(nodes[0], nodes[1], nodes[2], nodes[3], hub)

            let links = [east, west, north, south].map {
                Line(start: center, end: $0, width: 0.04, color: accent)
            }
            s.play(.draw(links[0]), .draw(links[1]), .draw(links[2]), .draw(links[3]), for: 0.9.s)
            s.play(.highlight(hub, color: warm, padding: 0.26), for: 1.s)

            if let font {
                s.add(
                    text("(i, j)", font, at: pt(0.62, -0.22), size: 0.26, color: dim),
                    text("(i+1, j)", font, at: pt(2.7, 0.1), size: 0.24, color: dim),
                    text("(i-1, j)", font, at: pt(-2.7, 0.1), size: 0.24, color: dim),
                    text("(i, j+1)", font, at: pt(0.95, 1.5), size: 0.24, color: dim),
                    text("(i, j-1)", font, at: pt(0.95, -1.3), size: 0.24, color: dim)
                )
            }

            story.caption("Same recipe, more neighbours — the undamped scheme is stable when r ≤ 1/√2.")
            write(formulas.courant2D, at: pt(3.5, 1.5), on: s, for: 0.8.s)
            highlight(formulas.courant2D, color: accent, on: s)
        }
    }

    // MARK: - 5. Interference: the double slit (Figure 1)

    private static func interferenceSlide(_ story: Story, font: Font?, formulas: Formulas) {
        story.slide("Interference") { s in
            story.caption("Now the payoff: aim a plane wave at a barrier with two openings.")

            // Incoming plane wave: vertical wavefronts marching right.
            let f1 = curve([SIMD2(-4.5, -1.9), SIMD2(-4.5, 1.9)], color: wave, width: 0.05)
            let f2 = curve([SIMD2(-4.0, -1.9), SIMD2(-4.0, 1.9)], color: wave, width: 0.05)
            let f3 = curve([SIMD2(-3.5, -1.9), SIMD2(-3.5, 1.9)], color: wave, width: 0.05)
            let inbound = Arrow(
                start: pt(-4.6, 0), end: pt(-2.4, 0),
                headLength: 0.3, headWidth: 0.22, width: 0.05, color: wave
            )
            s.play(.draw(f1), .draw(f2), .draw(f3), .draw(inbound), for: 1.s)

            // Barrier with two openings (holes) at y = ±0.85.
            let barX: Real = -1.7
            let barrier = [
                bar(x: barX, yLow: 1.2, yHigh: 2.7),    // top
                bar(x: barX, yLow: -0.5, yHigh: 0.5),   // septum between the holes
                bar(x: barX, yLow: -2.7, yHigh: -1.2),  // bottom
            ]
            s.add(barrier[0], barrier[1], barrier[2])

            if let font {
                s.add(
                    text("incoming plane wave", font, at: pt(-3.55, 2.25), size: 0.26, color: dim),
                    text("hole 2", font, at: pt(barX - 0.9, 0.85), size: 0.24, color: chalk),
                    text("hole 1", font, at: pt(barX - 0.9, -0.85), size: 0.24, color: chalk)
                )
            }

            // Two secondary sources: concentric ripples expand from each opening.
            let radii: [Real] = [0.55, 1.1, 1.65, 2.2, 2.75, 3.3]
            let lower = ripples(at: SIMD2(barX, -0.85), radii: radii, color: accent, width: 0.04)
            let upper = ripples(at: SIMD2(barX, 0.85), radii: radii, color: accent, width: 0.04)
            story.caption("Each opening becomes a fresh source. The two ripple trains overlap and add: u = u₁ + u₂.")
            s.play(.draw(lower), for: 1.2.s)
            s.play(.draw(upper), for: 1.2.s)

            if let font {
                s.add(text("u = u1 + u2", font, at: pt(barX + 1.0, 0), size: 0.3, color: accent))
            }

            // A screen on the right edge catches the fringe pattern: bright bands
            // where the paths reinforce, dark where they cancel.
            let screenX: Real = 4.6
            let screen = curve([SIMD2(screenX, -2.5), SIMD2(screenX, 2.5)], color: dim, width: 0.03)
            s.add(screen)
            let bright = bands(atX: screenX, ys: [0, 1.4, -1.4, 2.3, -2.3], color: warm)
            let dark = bands(atX: screenX, ys: [0.7, -0.7, 1.85, -1.85], color: danger)
            story.caption("Where the two paths differ by a whole wavelength, crests stack — bright fringes. Differ by a half, and they cancel — dark fringes. That is interference.")
            s.play(.draw(bright), .draw(dark), for: 1.s)

            // The fringe conditions, colour-keyed to the bands (gold reinforces,
            // red cancels), parked clear of the ripples in the upper right.
            write(formulas.constructive, at: pt(3.0, 2.3), on: s, for: 0.8.s)
            write(formulas.destructive, at: pt(3.1, 1.5), on: s, for: 0.8.s)
            // Last slide: no auto-clear fires, so the finished figure persists.
        }
    }

    // MARK: - Helpers

    private static func pt(_ x: Real, _ y: Real) -> Position { Position(x, y, 0) }

    /// Samples y = baseline + amplitude·sin(2π·cycles·t) across [x0, x1].
    private static func sineSamples(
        amplitude: Real, cycles: Real, x0: Real, x1: Real, baseline: Real, count: Int
    ) -> [SIMD2<Real>] {
        (0...count).map { i in
            let t = Real(i) / Real(count)
            let x = x0 + (x1 - x0) * t
            return SIMD2<Real>(x, baseline + amplitude * Real.sin(2 * Real.pi * cycles * t))
        }
    }

    /// An open, round-capped polyline as a stroked PathEntity.
    private static func curve(_ points: [SIMD2<Real>], color: Color, width: Real) -> PathEntity {
        strokes([Path.polygon(points: points, isClosed: false)], color: color, width: width)
    }

    /// Concentric right-facing arcs about a point — one PathEntity so a single
    /// `.draw` reveals the ripples expanding outward.
    private static func ripples(
        at center: SIMD2<Real>, radii: [Real], color: Color, width: Real
    ) -> PathEntity {
        strokes(radii.map { Path.arc(center: center, radius: $0, startAngle: -1.4, endAngle: 1.4) },
                color: color, width: width)
    }

    /// Short fat vertical bars at the given screen heights — the fringe pattern.
    private static func bands(atX x: Real, ys: [Real], color: Color) -> PathEntity {
        strokes(ys.map { Path.line(from: SIMD2(x, $0 - 0.22), to: SIMD2(x, $0 + 0.22)) },
                color: color, width: 0.16)
    }

    /// Merges contours into one stroked, unfilled PathEntity.
    private static func strokes(
        _ contours: [Path], color: Color, width: Real, cap: StrokeCap = .round
    ) -> PathEntity {
        var path = Path()
        for contour in contours { path = path.appending(contour) }
        let entity = PathEntity()
        entity.path = path
        entity.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color, strokeColor: color, strokeWidth: width, cap: cap, isFilled: false
        )
        return entity
    }

    /// A vertical barrier segment.
    private static func bar(x: Real, yLow: Real, yHigh: Real) -> Rectangle {
        let r = Rectangle(width: 0.22, height: yHigh - yLow, color: .gray)
        r.position = pt(x, (yLow + yHigh) / 2)
        return r
    }

    /// A filled disc node centred at `p`.
    private static func node(at p: Position, radius: Real, color: Color) -> Circle {
        let c = Circle(radius: radius, color: color)
        c.position = p
        return c
    }

    /// A dependency arrow that stops a hair short of both node discs.
    private static func dependency(from a: Position, to b: Position, color: Color) -> Arrow {
        let gap: Real = 0.3
        let direction = b - a
        let length = direction.length
        let start = length > 1e-4 ? a + direction * (gap / length) : a
        let end = length > 1e-4 ? a + direction * ((length - gap) / length) : b
        return Arrow(
            start: start, end: end,
            headLength: 0.22, headWidth: 0.16, width: 0.035, color: color
        )
    }

    /// A positioned text entity, left un-shown — for `.write` reveal targets.
    private static func made(
        _ string: String, _ font: Font, at p: Position, size: Real, color: Color
    ) -> TextEntity {
        let entity = TextEntity(string, font: font, fontSize: size, color: color)
        entity.position = p
        return entity
    }

    /// A font-gated label, shown immediately (added via `s.add`, not written).
    private static func text(
        _ string: String, _ font: Font, at p: Position, size: Real, color: Color
    ) -> TextEntity {
        made(string, font, at: p, size: size, color: color).shown()
    }

    /// Places a pre-built formula and writes it on; no-op when MathJax was absent.
    private static func write(_ formula: TextEntity?, at p: Position, on s: Scene, for duration: Duration) {
        guard let formula else { return }
        formula.position = p
        s.play(.write(formula), for: duration)
    }

    /// Neon-loops a formula for emphasis; no-op when it is absent.
    private static func highlight(_ formula: TextEntity?, color: Color, on s: Scene) {
        guard let formula else { return }
        s.play(.highlight(formula, color: color, padding: 0.25), for: 1.s)
    }
}
