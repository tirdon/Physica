# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift test                                  # host tests (macOS) — fast, no GPU/wasm needed
swift test --filter TimelineTests           # one suite
swift test --filter "TimelineTests/seek"    # tests whose name contains "seek" in that suite

# WebAssembly bundle → ./js (PackageToJS; the `js` subcommand is required)
swift package --swift-sdk 6.3-RELEASE-wasm32-unknown-wasip1-threads \
  --allow-writing-to-directory js js --use-cdn --output js

bun bunserver.js          # serve at http://localhost:3000 (COOP/COEP headers — required)
bun scripts/smoke.mjs     # headless smoke: runs the wasm bundle under Bun, no GPU; prints the demo timeline
```

If `swift test` after a wasm build fails with "command … not registered" errors, the shared llbuild state is crossed — `rm .build/build.db` and re-run.

Requirements: Swift 6.3 toolchain + the `6.3-RELEASE-wasm32-unknown-wasip1-threads` Swift SDK, Bun. The dev page must be served by `bunserver.js` (or anything sending COOP `same-origin` / COEP `require-corp`) — wasip1-threads refuses to run unless `crossOriginIsolated === true`.

## Big picture

Pure-Swift-6 SwiftWasm framework: RealityKit-style ECS + Manim-style scripted animation + WebGPU rendering + Hamiltonian rigid-body physics. Two targets with a hard boundary:

- **`Sources/Physica/`** — dependency-free core (never imports Foundation or JavaScriptKit). Builds and tests on macOS; this is where almost all logic and all tests live.
- **`Sources/PhysicsEngine/`** — wasm executable, everything wrapped in `#if os(WASI)`. Browser glue (`Web/`), the WebGPU renderer (`Render/`), and the demo script (`Demos/PendulumDemo.swift`). It consumes the core through two narrow seams: `Scene.snapshot()` → `SceneSnapshot` (flattened world-space primitives) and the `RenderBackend` protocol. Host tests assert snapshots via `MockRenderBackend`; the renderer is a dumb consumer.

`Math/TypeAtlas.swift` defines `Real` (`Float` on wasm, `Double` on macOS), `Position = SIMD3<Real>`, and the libm shims (`Real.sin` etc. — Apple's simd module doesn't exist on WASI, hence the hand-rolled `Quaternion`/`Matrix4`). Write numeric code against `Real` and keep test assertions tolerance-based.

### Concurrency model (load-bearing, applies everywhere)

The whole mutable object graph (`Entity`, `Scene`, `Timeline`, `Animation`, `Engine`, `System`, web glue) is `@MainActor`; beneath it is a pure `Sendable` value layer (Transform, Path, Mesh, Color, snapshots, event enums). Conventions that exist because of this:

- `Component` is deliberately **not** Sendable (`UpdaterComponent` stores `@MainActor` closures).
- `Entity.id` is a `nonisolated let UInt64` from a monotonic counter (deterministic for tests; no UUID/Foundation); `==`/`hash` use id only.
- MainActor classes expose `var debugString: String` instead of `CustomDebugStringConvertible` (which is nonisolated). Tests assert on `debugString`, formatted with the hand-rolled fixed-decimal `fmt()` so Float/Double hosts print identically.
- AsyncStreams (`Timeline.eventStream()`, `Scene.inputStream()`) carry Sendable enums only.

### Animation = the currency type

Entity methods (`move/shift/scale/rotate/color/fade/opacity/morph`) are **deferred descriptors** — they return an `Animation` and mutate nothing. Chained calls accumulate (`star.opacity(0.8).shift(-1.j)` carries both blueprints as `AnimationPair`s); `scene.add` marks pair ids consumed and `play` filters them, which is why a stored handle (`let bob = Circle().move(to: p)`) can be re-animated without double-applying its original move. `scene.add`, `scene.play`, `scene.wait`, `scene.pause(System.self)` all enqueue clips and also return `Animation`, so everything composes. Play forms: variadic `play(_:for:easing:)`, `play(group:)`, builder `play(3.s) { ... }`, and composer `play { clip in clip.add(anim, for: 1.s, offset: ...) }` (one clip, per-animation timing). Duration precedence: `play(for:)` > `animation.duration` > blueprint default (1 s).

Write/draw/erase/highlight are **static `Animation` factories**, not entity methods: `scene.play(.write(title))`, `.draw(shape)`, `.erase(shape or title)`, `.highlight(entity)`. They resolve via a concrete `play(_: Animation...)` overload (leading-dot syntax can't see statics through `any Animatable`). Write/draw blueprints set `introducesTarget`, so `play` auto-adds the entity — no `scene.add` first; erase is the same blueprint `reversed` (value 1→0, fill fades then stroke retracts, last glyph first) plus `removesTargetAtEnd`, which drops a `RemoveEntityTrack` at the pair's end time. Both are scrub-safe: rewinding un-adds / re-inserts at the original root index (painter's order survives). An explicit `scene.add` earlier keeps ownership — the play-clip auto-add only claims entities absent at clip begin.

`.highlight(entity, color:padding:)` is a neon border chase (loading-loop): a transient rounded-rect `PathEntity` is built around the subject's bounds at clip begin, the stroke head runs one lap (`strokeProgress`) while the tail follows (`strokeStart`, head window 62%, tail leaves at 38%), and nothing remains at the end — `introducesTarget` + `removesTargetAtEnd` on one blueprint. Because the border is introduced and removed by the *same* clip, `RemoveEntityTrack` resolves its root index lazily in `apply` (at `begin` the AddEntitiesTrack hasn't inserted it yet).

`saveState()` / `restoreState()` (Manim's save_state/Restore) work on any Animatable and on `Group` bags (members): save is a **0-duration clip** that captures transforms at that point of the *timeline* (begin-captured — the state usually only exists during playback, e.g. mid-swing), stored in `SavedStateComponent`; restore animates `entity.transform` back to it via `PropertyTrack<Transform>` (no capture → no-op). Scrub-safe: rewinding past the save removes/restores the component. Note a clip sitting at t = X stays applied when you seek exactly to X — "before the clip" means strictly earlier.

Text/formula glyph slices: `title[0]`, `title[1..<4]`, `formula[(n - 4)...]` return a `GlyphSlice` with `color(_:)`, `color(mix: [Color])` (multi-stop ramp across the slice) and `fade(to:)`/`opacity(_:)` — deferred Animations targeting the parent entity. Per-glyph overrides live on `PositionedGlyph` (color/opacity), beat the entity style in the snapshot, and rewind to their prior values exactly (a nil override comes back as nil). Out-of-range slices clamp to no-ops. Entity-level `color(_:)` animates the shared `RenderStyleComponent` instead; `text.color(mix:)` is the whole-text gradient. Note `(n - 4)...` needs the parens — postfix `...` binds tighter than `-`.

### Math (MathJax → SVG → Path)

Math formulas are `TextEntity`s, so write/erase/morph apply unchanged. Core side (host-testable): `Path.svg(d)` parses SVG path data (full command set, arcs lower to cubics), `MathSVG.glyphs(fromSVG:)` walks MathJax tex-svg markup (defs/use/g-transform/rect; each `<use>`/`<rect>` = one glyph, document order = stagger order; output em units, y flipped back up, centered on bounds), `TextEntity.math(svg:fontSize:color:)` wraps it. Web side: `MathJaxLoader.formula("\\frac{g}{\\ell}", fontSize:)` injects `tex-svg.js` from jsDelivr (`crossorigin` — COEP needs the CORS headers) with **`fontCache: "local"`** (global cache would put glyph defs outside the svg and `MathSVG` throws `unknownReference`), polls for `MathJax.startup.promise`, then `tex2svg(...).querySelector("svg").outerHTML`. No DOM (Bun smoke) → `.unavailable`, demo skips math. Test fixtures in `MathSVGTests` are genuine mathjax-full output — regenerate with bun + `mathjax-full` if MathJax structure ever drifts.

### Mesh shading and path textures

`mesh.shaded(.toon)` (= `.toon(bands: 3, outline: 0.035)`) quantizes diffuse into flat bands and adds an inverted-hull outline; `entity.textured(.chalk / .pencil)` applies world-anchored procedural grain to any path-producing entity (shapes, text, math). Both ride the spare `params` vec4 in the 256-byte per-draw uniform slot (paths: x = texture mode 0/1/2, 3 = blackboard backdrop quad; meshes: x = shading, y = bands, z = outline inflate) — core carries them via `MeshDraw.shading` / `PathStyle.texture`. Gotchas: our UV-grid meshes wind outward faces **CW**, so the outline pipeline culls `"back"` (not `"front"`) to drop the hull's camera side; hard-edged meshes (box) crack at corners when inflated — keep outlines on smooth surfaces. Texture noise hashes world xy, so grain sticks to geometry, not the screen.

Strokes draw the **trim window `[strokeStart, strokeProgress]`** of the path's total arc (continuous: whole quads + fractional quads on both boundary segments — integer-only capping pops whole sides on low-vertex shapes). Write/draw/erase only move the head; highlight moves both. `style.neon` makes the uploader emit two stroke commands over the same window: a 3× wide translucent glow in the tube color under a whitened core.

`RenderStyleComponent.strokeWidth` is **normalized 0...1**: 1 = 10% of the frame's longest side, resolved to world units in `Scene.snapshot()` (clamped, `PathStyle.strokeWidth` carries the result). At the default fit-10 camera the factor is exactly 1, so values read like world units there. `scene.size` is the visible frame's world size (logged to the console at boot).

`scene.background = .color(c)` drives the clear color; `.blackboard` (= `.blackboard(tint:)`, deep-green slate) additionally draws a fullscreen flat quad (params.x = 3: value-noise smudge + chalk dust, world-anchored) before meshes/paths — it rides `SceneSnapshot.background` + `snapshot.frame` (the camera's visible rect sizes the quad).

### Frame and camera

Default camera is `.orthographicFit(extent: 10)`: the longest visible side is 10 world units (aspect 1.6 → 10 × 6.25; portrait → 10·aspect × 10). `move(to: Unit)` resolves against this frame at clip start and pins that entity's own bounds to the edge — separate calls in one play each move independently (no implicit grouping; user decision 2026-06-11). To move entities together, wrap them: `Group(pivot, string, bob).move(to: .bottom)` (`GroupedMoveToUnitBlueprint`) pins the union of the members' bounds and shifts every member by one shared delta, so a pendulum keeps its string length. The group works as a transient bag — it never joins the scene; its `Animatable...` init also accepts stored handles (`let bob = Circle().move(...)`), and `Group.addChild` only overwrites a child's scene pointer when the group itself is in a scene. Wall defaults sit just inside the frame (ceiling/floor y ±2.9, sides x ±4.6). Bodies outside **3× the frame** are frozen by `HamiltonianSystem` (no integration, no contacts) — physics integration tests use a big explicit camera (`PhysicsTests.makeWorld`) to stay clear of the cull. The Shift overlay culls labels outside the viewport and skips ~0-opacity entities.

### Scrub-safe timeline contract

The timeline is an append-only clip history. Every track implements `begin(in:)` (idempotent start-value capture) / `apply(at:in:)` (pure in t) / `rewind()`. `seek` forward applies intermediate clips at their end time; backward calls `rewind()` in reverse (so entities added by an `add` clip disappear when you scrub before it). During seek all systems are suspended and one updater pass runs after. **System-driven state (pendulum, physics) intentionally freezes during scrub — it is not replayed.** Any new track type must honor begin/apply/rewind or scrubbing breaks; snap exactly to endpoints at t≤0 / t≥1 (see PathMorphTrack).

Per-frame order in `Scene.update`: timeline.advance → systems (skipped while paused/suspended) → layouts → updaters. Updaters (`entity.updater = {...}` or `entity.bind(\.end, to: bob, \.position)`) also run once after every seek.

### Physics

Hamiltonian/momentum form: state is (transform, p, L); velocities are derived (`ω = R I⁻¹ Rᵀ L`), integrated symplectically at a fixed 1/240 step with an accumulator (`HamiltonianSystem.step(_:in:)` is public for deterministic tests). Contacts are SDF surface-sample based, uniform across sphere/box/ellipsoid/torus. Gotcha: **restitution = min(A, B)** and the default is 0.4, so bounce tests must set restitution explicitly on the static body too. Physics entities should be scene roots.

### JavaScriptKit gotchas (PhysicsEngine only; JSKit pinned to main @453b841)

- Heterogeneous descriptor dicts: `[String: JSValue]` + `.jsValue` — existential `[String: ConvertibleToJSValue]` doesn't conform; mixed literals need explicit `JSValue.number(...)`.
- `JSObject` dynamic methods need `!` (`global.requestAnimationFrame!`); ambiguous property chains need a type annotation (`let gpu: JSValue = navigator.gpu`).
- Await promises with the function form `JSPromise(...).value()` — the `.value` property trips sendability from @MainActor.
- JSClosure bodies: do work inside `MainActor.assumeIsolated { ... }` returning Void, then `return .undefined` outside (JSValue isn't Sendable).
- The BridgeJS plugin is configured in Package.swift but zero `@JS` is used — delete the plugin line if it ever breaks the build.

## Verifying renderer/web changes

`swift test` covers everything in the core. For anything touching `Render/` or `Web/`, rebuild the wasm bundle and check visually: headless Chrome renders WebGPU on macOS via puppeteer-core with `--headless=new --use-angle=metal --enable-unsafe-webgpu` against the running bun server (screenshot the canvas at chosen timeline times). `bun scripts/smoke.mjs` is the GPU-free sanity check that the bundle still boots.
