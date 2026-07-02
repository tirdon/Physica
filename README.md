# Physica

A lightweight SwiftWasm framework in pure Swift 6 — RealityKit-flavored ECS with a
Manim-style scripted animation API, rendered with WebGPU in the browser.

- **ECS** — `Entity` + type-keyed `ComponentSet`, `System` protocol with `@MainActor update(context:)`, `EntityQuery`, `Group`/`Row`/`Column`/`Grid` layouts.
- **Scripted animation** — `scene.add` / `scene.play` / `scene.wait` / `scene.pause(System.self)` enqueue clips on an append-only `Timeline`; every call and every entity animation method returns the same `Animation` currency type, so everything composes (including a result builder).
- **Scrub-safe** — `seek(t)` replays/rewinds clips deterministically (entities appear/disappear at their `add` clip), pauses all systems, and re-runs updaters. The playback slider in `example1.html` drives it.
- **Updaters** — `entity.updater = { ... }` (Manim `add_updater` style) or type-safe `entity.bind(\.end, to: bob, \.position)`; both stored in `UpdaterComponent`, run after systems each frame and after every seek.
- **Vector graphics** — `Path` (line/quad/cubic), `Circle`/`Rectangle`/`Triangle`/`Line`/`Arrow`/`Wall`, stencil-then-cover GPU fills (concave shapes and holes are exact), stroke reveal `draw()`, topology-matched `morph(to:)`.
- **Text** — pure-Swift TrueType parser (`glyf`, cmap 4/12), `TextEntity("…", font:)` with `write()`: glyph-staggered stroke draw, then fill fade.
- **Math** — MathJax renders TeX → SVG in the browser automatically (zero install — `MathJaxLoader.formula` fetches `tex-svg.js` from jsDelivr). `write()`/`erase()`/`morph()` work unchanged on formulas; per-glyph slicing (`formula[0]`, `formula[1..<4]`) for coloring and animation. `MathSVG` also parses dvisvgm-style markup, so you can pre-bake `.svg` glyph assets with an external `latex` + `dvisvgm` pipeline and load them via `TextEntity.math(svg:)` (no MathJax at runtime).
- **3D** — UV-grid `Mesh` primitives (sphere/box/ellipsoid/torus/plane), Lambert-shaded `MeshEntity`, mesh `morph(to:)`, toon shading (`.shaded(.toon)`).
- **Plotting** — `Plane` with axes/grid/labels, `plane.graph(of:)`, `plane.field { … }`, `plane.streamlines { … }`, `plane.plot(points)`. Data is the animatable — graphs morph via polyline lerp.
- **Annotations** — `SurroundingRectangle`, `Brace`, `Dimension`, `Callout` — entities that frame or point at another entity's bounds.
- **Story mode** — scroll-driven presentations: `Story(scene:)` partitions the timeline into slides with auto-clear, `carry`/`clear` scoping, camera transitions, action buttons, and arrow-key/swipe navigation.
- **Algebra** — exact `Rational`, `Expression` AST with TeX parser, CAS `Simplifier`, `Equation` moves (Equalynx-style: drag a token across `=` to apply its inverse to both sides), vector `Projection`.
- **Equation game** — interactive drag-and-drop equation solving: `EquationEntity` with baseline-aligned tokens, `EquationGame` drop target, `PlaceholderEquationEntity` goal matching, `LiteralEntity` draggable clones.
- **Interactions** — `scene.interact(...)` plays animations in parallel (pause-independent); `DragCoordinator` with `DraggableComponent`, `DropTargetComponent`, `TapComponent`, `HoverComponent`, `DoubleTapComponent`; `InteractionRunner` for scrub-independent effects.
- **Physics** — Hamiltonian rigid bodies (`p`, `L` integrated symplectically; velocities derived), analytic inertia tensors, SDF surface-sample contacts + impulse response for sphere/box/ellipsoid/torus.
- **Camera** — `scene.frame` is an animatable `SceneCamera` entity: `scene.play(scene.frame.zoom(to: 7), for: 1.s)` — camera moves are normal scrubbable clips.
- **Textures & shading** — `entity.textured(.chalk / .pencil)` procedural grain on any path entity; `mesh.shaded(.toon)` flat-band quantization + inverted-hull outline; `scene.background = .blackboard` value-noise slate.
- **Web glue** — WebGPU renderer written in Swift via JavaScriptKit, `requestAnimationFrame` driver, pointer/keyboard input streams, IntersectionObserver visibility gating, Shift-held entity-index overlay, playback controls.

## Quick start

```sh
# Host tests (macOS, Real == Double)
swift test

# WebAssembly bundle (Real == Float) → ./js-example1
swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads \
  --allow-writing-to-directory js-example1 js --use-cdn --output js-example1 --product Example1

# Serve with the COOP/COEP headers wasip1-threads needs
bun bunserver.js          # → http://localhost:3000

# Headless smoke test (no GPU needed; prints the demo timeline)
bun scripts/smoke.mjs
```

Requirements: Swift 6.3 toolchain + the `6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads`
Swift SDK, Bun, and a WebGPU-capable browser (Chrome/Edge 113+, Safari 18+).
Math formulas work out of the box — MathJax is loaded from a CDN at runtime, no
extra tools needed.

## The API in one example

```swift
scene.registerSystem(PendulumSystem.self)

let pivot = Wall(face: .down)                    // = ceiling
let center = pivot.center
let string = Line(start: center, end: center - 4.j)
let bob = Circle().move(to: string.end)          // descriptor — applied by add()
string.updater = { $0.end = bob.position }       // derived state, every frame
scene.add(pivot, string, bob)                    // 0-duration clip on the timeline
scene.play(bob.move(to: 1.i + 1.j), for: 2.s)
scene.play(bob.move(to: .origin))                // default 1 s
scene.wait()                                     // systems keep updating

string.components[PendulumComponent.self] = PendulumComponent(.string, string)
bob.components[PendulumComponent.self] = PendulumComponent(.bob, bob)
scene.wait()                                     // custom system drives the bob
scene.pause(PendulumSystem.self)                 // suspended for 1 s, then resumes
scene.play(pivot.move(to: .bottom), string.move(to: .bottom), bob.move(to: .bottom))

let a1 = Animation(triangle.shift(-1.i), for: 2.s, offset: 1.s)
scene.play(group: a1, .init(square.shift(1.i), for: 3.s))   // one clip, offsets kept
```

### Static animation factories

```swift
scene.play(.write(title))               // stroke draw + fill fade, auto-adds entity
scene.play(.draw(shape))                // stroke reveal only
scene.play(.erase(shape))               // reverse of write/draw, removes at end
scene.play(.highlight(entity))          // neon border chase, self-cleaning
scene.play(.shake(entity))              // damped horizontal wobble
```

### Story mode

```swift
let story = Story(scene: scene)

story.slide("Setup", transition: .fade) { s in
    scene.add(plane, graph)
    scene.play(.write(title))
    s.carry(plane)                       // persists past this slide
}

story.slide("Analysis") { s in
    scene.play(graph.plot(newData))      // data morph
    s.clear(title)                       // drop earlier content mid-slide
}
```

### Plotting

```swift
let plane = Plane(x: -2...5, y: -1...3, gridStep: 1, font: font)
let graph = plane.graph(of: { sin($0) }, samples: 200)
let field = plane.field { p in Position(p.y, -p.x, 0) }

scene.add(plane)
scene.play(.draw(graph))
scene.play(graph.plot(of: { cos($0) }))  // animate to new function
```

### Interactions

```swift
entity.components[DraggableComponent.self] = DraggableComponent(
    payload: myData,
    onTap: { entity in scene.interact(.highlight(entity)) }
)
entity.components[DropTargetComponent.self] = DropTargetComponent(
    accepts: { $0 is MyPayload },
    onDrop: { target, payload, pos in .accepted }
)
```

`Sources/PhysicaDemo/Example1/Demos/PendulumDemo.swift` runs the pendulum demo script;
`Sources/PhysicaDemo/Example2/EquationStoryDemo.swift` is a full scroll-driven
equation-solving story at `example2.html`.

## Layout

```
Sources/Physica/            dependency-free core — builds & tests on macOS and wasm
  Math/      Real/Position TypeAtlas (#if wasm32 → Float, macOS → Double), sugar
             (1.i, 2.s), Quaternion, Matrix4, Color, Easing, Interpolatable
  Algebra/   Rational, Expression + parser, Simplifier, Equation + moves,
             Projection, DisplayToken — a pure leaf (no other dependencies)
  Geometry/  Path + flatten, PathMorph, SVGPath, Mesh + MeshMorph — value types
  Typesetting/ TrueType parser (Font, cmap, ByteReader), MathSVG + TagScanner,
             Affine2 — markup → glyph paths, no scene coupling
  ECS/       Component(Set), Entity, System/EntityQuery, Group, Layouts, Updater
  Animation/ Animation + blueprints, tracks (begin/apply/rewind), Clip, Timeline;
             Effects/ Highlight, Shake, SaveState
  Scene/     Scene (scripted API, snapshot), Camera, SceneCamera (animatable),
             Engine, RenderBackend, ClipComposer, Snapshot, Unit
  Entities/  PathEntity + shapes (Circle…Arrow, Wall), TextEntity + write(),
             GlyphSlice, MeshEntity, Annotations
  Plotting/  Plane + AxisOptions, Graph, VectorField, Streamlines, plot tracks
  Interaction/ Input events, SwipeRecognizer, DragComponents, DragCoordinator,
             InteractionRunner
  Story/     Story, StoryPlayer, Transitions/ (fade, zoom, push, morph)
  Physics/   PhysicsShape/Body/Motion, SDFs, HamiltonianSystem
  EquationGame/ EquationEntity, EquationGame, LiteralEntity,
             PlaceholderEquationEntity, TokenGlyphProvider
  WASM/      (all #if os(WASI) — links JavaScriptKit conditionally)
    Render/  WebGPURenderer + WGSL shaders, GeometryUploader, GPUHelpers
    Web/     WebRuntime, StoryRuntime, rAF driver, InputBindings,
             PlaybackControls, DebugOverlay, FontLoader, MathJaxLoader,
             MathJaxTokenProvider, VisibilityObserver
Sources/PhysicaDemo/        wasm executables (browser demo apps)
  Example1/  pendulum animation demo — Example1.swift boots PendulumDemo;
             bundle js-example1/, shell example1.html
  Example2/  equation story demo — Example2.swift boots EquationStoryDemo;
             bundle js-example2/, shell example2.html
  Example0/  standalone wave-equation story; bundle js-example0/, example0.html
Sources/StoryStudio/        WYSIWYG story editor; bundle js-studio/, studio.html
index.html                  landing page linking to all web demos
Tests/PhysicaTests/         swift-testing suites, debugString/snapshot assertions
Tests/StoryStudioTests/     host tests for the editor's Document/Compiler/History
```

## Testing

```sh
swift test                                  # all host tests (~42 suites)
swift test --filter TimelineTests           # one suite
swift test --filter "TimelineTests/seek"    # tests whose name contains "seek"
```

Tests cover ECS, animation, timeline, morphs, plotting, algebra, equation game,
drag/drop, story player, slide transitions, interactions, camera, snapshots,
physics, SVG paths, MathSVG, font parsing, glyph slices, annotations, and more.
All host tests run with `Real == Double`; numeric assertions are tolerance-based
for Float/Double parity.

## Notes & current limits

- The core never imports Foundation or JavaScriptKit; everything is `@MainActor`
  classes over `Sendable` value types (Swift 6 strict concurrency, zero warnings).
- The WASM subtree (`Sources/Physica/WASM/`) links JavaScriptKit through a
  `.when(platforms: [.wasi])` conditional dependency — host builds stay JSKit-free.
- Scrubbing replays *animation* state; custom-system state (pendulum, physics)
  intentionally freezes during a scrub and resumes live afterward.
- Interactions (`scene.interact`, drag/drop) run outside the paused gate — they
  work while the timeline rests paused (essential for story mode).
- Fonts: TrueType `glyf` outlines only (no CFF/.otf), cmap formats 4/12,
  offset-only composites. The demo fetches Roboto from jsDelivr (`FontLoader.defaultURL`).
- Math works with **MathJax alone** — no LaTeX installation needed. MathJax
  `tex-svg.js` is fetched from jsDelivr at runtime with `fontCache: "local"`;
  no DOM (Bun smoke) → `.unavailable`, demo skips math. `MathSVG` also accepts
  dvisvgm-style markup (locked by `DVISVGCompatTests`), so you can pre-bake
  `.svg` glyph assets offline and load them with `TextEntity.math(svg:)`.
- Physics contacts are SDF surface samples — uniform across all four shapes,
  approximate rather than manifold-perfect; tune `surfaceSamples(target:)` for fidelity.
- `@JS`/BridgeJS export is configured but unused (all interop is JSClosure/JSObject);
  the plugin line in `Package.swift` can be dropped if it ever misbehaves.

## License

[The Unlicense](LICENSE) — public domain.
