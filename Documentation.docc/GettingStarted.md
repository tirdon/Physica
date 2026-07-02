# Getting Started

Build, run, and write your first Physica scene.

## Overview

Physica is a Swift package built around the `Physica` library (the whole
framework) plus thin wasm executables that host it in the browser:
`Example1` (the pendulum animation demo), `Example2` (the equation story demo),
`Example0` (a minimal standalone example), and `StoryStudio` (a WYSIWYG story
editor). Almost everything lives in the library and runs on macOS, so the
fastest feedback
loop is `swift test` — no GPU or wasm toolchain required.

### Requirements

- The Swift 6.3 toolchain plus the `6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads`
  Swift SDK.
- [Bun](https://bun.sh) to serve the bundle and run the headless smoke test.
- A WebGPU-capable browser (Chrome/Edge 113+, Safari 18+) to see pixels.

### Build & test

```sh
# Host tests (macOS, Real == Double) — fast, no GPU/wasm needed
swift test
swift test --filter TimelineTests          # one suite

# WebAssembly bundle (Real == Float) → ./js-example1
swift package --swift-sdk 6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads --allow-writing-to-directory js-example1 js --use-cdn --output js-example1 --product Example1

# Serve with the COOP/COEP headers wasip1-threads needs
bun bunserver.js          # → http://localhost:3000

# Headless GPU-free sanity check (prints the demo timeline)
bun scripts/smoke.mjs
```

The dev page *must* be served with COOP `same-origin` / COEP `require-corp`
(`bunserver.js` does this) — wasip1-threads refuses to run unless
`crossOriginIsolated === true`.

> Tip: If `swift test` after a wasm build fails with "command … not registered",
> the shared llbuild state is crossed — `rm .build/build.db` and re-run.

## Your first scene

A ``Scene`` is the authoring surface. Entity methods return deferred
descriptors; ``Scene/add(_:)`` and `play` put them on the ``Timeline``.

```swift
let scene = Scene()

let title = TextEntity("Hello, Physica", font: font)
let dot   = Circle().move(to: .top)      // descriptor — nothing applied yet

scene.add(dot)                            // 0-duration clip: dot enters here
scene.play(.write(title))                 // write/draw auto-add their target
scene.play(dot.move(to: .bottom), for: 2.s)
scene.play(dot.color(.orange))            // default 1 s
```

A few conventions worth internalizing early:

- **Units sugar.** `1.i`, `2.j`, `1.s` build positions and durations
  (`1.i + 1.j` is a world point; `2.s` is a ``Duration``). ``Unit`` values like
  `.top`, `.bottom`, `.origin` resolve against the camera frame at clip start.
- **Camera frame.** The default camera is an orthographic fit with the longest
  visible side at 10 world units; `scene.size` (logged at boot) is the visible
  frame. ``Unit`` moves pin an entity's *own* bounds to that frame's edge.
- **Write/draw/erase/highlight** are static ``Animation`` factories, not entity
  methods: `scene.play(.write(title))`, `.draw(shape)`, `.erase(shape)`,
  `.highlight(entity)`. Write and draw set up their own target, so you don't
  `add` first.

## Adding behavior

Per-frame logic comes from updaters and systems:

```swift
string.updater = { $0.end = bob.position }     // runs every frame and after seeks
string.bind(\.end, to: bob, \.position)        // type-safe equivalent
```

For stateful simulation, register a ``System`` (or the built-in
``HamiltonianSystem`` for rigid-body physics) with
``Scene/registerSystem(_:)``. Note systems are *suspended during a scrub* — see
<doc:Concurrency>.

## Next steps

- <doc:ScriptedAnimation> — the animation currency type in depth.
- <doc:Plotting> — graphs, vector fields, and streamlines on a ``Plane``.
- <doc:Interactions> — drag, drop, tap, and parallel interactions.
- <doc:StoryMode> — turn one timeline into a scroll-driven lesson.
