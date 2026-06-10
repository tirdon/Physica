# Physica

A lightweight SwiftWasm framework in pure Swift 6 — RealityKit-flavored ECS with a
Manim-style scripted animation API, rendered with WebGPU in the browser.

- **ECS** — `Entity` + type-keyed `ComponentSet`, `System` protocol with `@MainActor update(context:)`, `EntityQuery`, `Group`/`Row`/`Column`/`Grid` layouts.
- **Scripted animation** — `scene.add` / `scene.play` / `scene.wait` / `scene.pause(System.self)` enqueue clips on an append-only `Timeline`; every call and every entity animation method returns the same `Animation` currency type, so everything composes (including a result builder).
- **Scrub-safe** — `seek(t)` replays/rewinds clips deterministically (entities appear/disappear at their `add` clip), pauses all systems, and re-runs updaters. The playback slider in `index.html` drives it.
- **Updaters** — `entity.updater = { ... }` (Manim `add_updater` style) or type-safe `entity.bind(\.end, to: bob, \.position)`; both stored in `UpdaterComponent`, run after systems each frame and after every seek.
- **Vector graphics** — `Path` (line/quad/cubic), `Circle`/`Rectangle`/`Triangle`/`Line`/`Arrow`/`Wall`, stencil-then-cover GPU fills (concave shapes and holes are exact), stroke reveal `draw()`, topology-matched `morph(to:)`.
- **Text** — pure-Swift TrueType parser (`glyf`, cmap 4/12), `TextEntity("…", font:)` with `write()`: glyph-staggered stroke draw, then fill fade.
- **3D** — UV-grid `Mesh` primitives (sphere/box/ellipsoid/torus/plane), Lambert-shaded `MeshEntity`, mesh `morph(to:)`.
- **Physics** — Hamiltonian rigid bodies (`p`, `L` integrated symplectically; velocities derived), analytic inertia tensors, SDF surface-sample contacts + impulse response for sphere/box/ellipsoid/torus.
- **Web glue** — WebGPU renderer written in Swift via JavaScriptKit, `requestAnimationFrame` driver, pointer/keyboard input streams, IntersectionObserver visibility gating, Shift-held entity-index overlay, playback controls.

## Quick start

```sh
# Host tests (macOS, Real == Double)
swift test

# WebAssembly bundle (Real == Float) → ./js
swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads \
  --allow-writing-to-directory js js --use-cdn --output js

# Serve with the COOP/COEP headers wasip1-threads needs
bun bunserver.js          # → http://localhost:3000

# Headless smoke test (no GPU needed; prints the demo timeline)
bun scripts/smoke.mjs
```

Requirements: Swift 6.3 toolchain + the `6.3-RELEASE-wasm32-unknown-wasip1-threads`
Swift SDK, Bun, and a WebGPU-capable browser (Chrome/Edge 113+, Safari 18+).

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

`Sources/PhysicsEngine/Demos/PendulumDemo.swift` runs this script (plus a text
write, morph chain, and physics drop) on the single scrubbable timeline you see
at `index.html`.

## Layout

```
Sources/Physica/            dependency-free core — builds & tests on macOS and wasm
  Math/      Real/Position TypeAtlas (#if wasm32 → Float, macOS → Double), sugar
             (1.i, 2.s), Quaternion, Matrix4, Color, Easing, Unit
  ECS/       Component(Set), Entity, System/EntityQuery, Group, Layouts, Updater
  Animation/ Animation + blueprints, tracks (begin/apply/rewind), Clip, Timeline
  Geometry/  Path + flatten, shapes, PathMorph, Mesh + MeshMorph
  Text/      TrueType parser, TextEntity + write()
  Physics/   PhysicsShape/Body/Motion, SDFs, HamiltonianSystem
  Scene/     Scene (scripted API, snapshot), Camera, Engine, RenderBackend
Sources/PhysicsEngine/      wasm executable — browser entry ("visual test host")
  Render/    WebGPURenderer + WGSL (stencil-cover fills, strokes, Lambert meshes)
  Web/       rAF driver, input bindings, IntersectionObserver, playback, overlay,
             FontLoader (fetch + parse TTF)
  Demos/     PendulumDemo (spec script + showcase)
Tests/PhysicaTests/         swift-testing suites, debugString/snapshot assertions
```

## Notes & current limits

- The core never imports Foundation or JavaScriptKit; everything is `@MainActor`
  classes over `Sendable` value types (Swift 6 strict concurrency, zero warnings).
- Scrubbing replays *animation* state; custom-system state (pendulum, physics)
  intentionally freezes during a scrub and resumes live afterward.
- Fonts: TrueType `glyf` outlines only (no CFF/.otf), cmap formats 4/12,
  offset-only composites. The demo fetches Roboto from jsDelivr (`FontLoader.defaultURL`).
- Physics contacts are SDF surface samples — uniform across all four shapes,
  approximate rather than manifold-perfect; tune `surfaceSamples(target:)` for fidelity.
- `@JS`/BridgeJS export is configured but unused (all interop is JSClosure/JSObject);
  the plugin line in `Package.swift` can be dropped if it ever misbehaves.
