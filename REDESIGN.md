# Physica — Architecture Review & Redesign Proposal

*2026-07-02 · produced from a full read of the animation/scene/plotting/story core, a
reference-level dependency scan across all 13 subsystems, `Package.swift`, and the three
consumers (Example0, Example1, StoryStudio).*

*Status update (same day): user approved **all** phases. Phases 1–4 are landed and
green (406 tests / 45 suites; three wasm bundles rebuilt on the Swift 6.3.2 toolchain +
`6.3-SNAPSHOT-2026-06-11-a-wasm32-unknown-wasip1-threads` SDK after the machine's 6.3.0
toolchain disappeared mid-session; demo smoke byte-identical). Notable deltas from the
plan as written: 4a gained an adoption ledger so child-first adds scrub-symmetrically;
4b attaches plots to their plane **lazily at the reveal clip** (eager `addChild` would
have shown plots before their `.draw`) and keeps `lines` plane-local with a private
data-space mirror instead of making `graph(of:)` escaping; Phase 3's type-level survey
found the public surface ~95 % intentional, so curation was surgical (see API.md) rather
than a mass demotion.*

*Phase 5 (same day): landed. Eleven layered targets behind the `@_exported` umbrella;
`package` access at the kernel seams; per-file imports injected mechanically. The split
immediately caught four real layering leaks the in-place phases had missed: the morph
blueprints/tracks and `TextEntity.math` lived in Geometry/Typesetting (moved kernel-side
as `MorphAnimations.swift` / `TextEntityMath.swift`), `Transform`/`Bounds` lived in ECS
(moved to Math/Geometry), `PositionedGlyph` was nested in the kernel's TextComponent while
being the parsers' output type (now top-level in Typesetting, typealias preserved), and
`Scene.insert`'s plot routing named a Plotting type (generalized to the kernel-pure
`GroupAnchored`). One deliberate impurity kept and documented: Kernel → Algebra, because
`DragPayload` carries `Expression`/`ProjectionAxis`.*

---

## 0. Executive summary

Sources/Physica is 90 files / 15.3k lines across 13 directories, with zero TODO markers
and a design that is deliberate at every level I checked. **This is not a rescue.** The
redesign case is about three kinds of accumulated pressure:

1. **The taxonomy no longer matches the architecture.** Directories mix pure value code
   with scene-coupled entities (Geometry holds both `Path` and the whole `Plane` chart
   stack; Typesetting holds both the TrueType parser and `TextEntity`; Math holds the
   scene-facing `Unit`). The documented layering exists only in prose.
2. **Two real semantic faults hide under documented workarounds.** Scene membership is
   encoded in two half-synced places (§1.3-b), and plotting entities are half-coupled to
   their `Plane` (§1.3-c). Both are the *root causes* of the "never `scene.add` a plane
   child you also `.draw`" and "position the plane before sampling" rules in CLAUDE.md.
3. **The public surface has sprawled** to ~900 `public`/`open` declarations for a
   framework whose intended API is maybe half that, and the top-level docs (README layout,
   CLAUDE.md build commands) are one refactor behind the tree.

### Phase menu

| Phase | What | Size | Risk | Breaks API? |
|---|---|---|---|---|
| 1 | Quiet wins: µ-fixes + split oversized files | S | minimal | no |
| 2 | Re-layer the directory tree + sync all docs | M | minimal (git mv) | no |
| 3 | Public-surface curation (public → internal) | M | low (compiler-driven) | no* |
| 4a | Fix scene-membership dual encoding | M | medium | semantics only |
| 4b | Plotting entities become plane children | M–L | medium | yes (small, listed) |
| 4c | Camera `move(to:)` z-preservation | S | low | semantics only |
| 5 | SwiftPM target split (compiler-enforced layers) | L | medium-high | no (umbrella re-export) |

\* Phase 3 removes symbols nothing in the repo uses; out-of-repo consumers would notice.

**Recommended order: 1 → 2 → 3 → 4a → 4b → 4c → 5.** Phases 1–3 are churn-only and make
everything after them smaller. Phase 4 changes real semantics behind green tests. Phase 5
is genuinely optional and rides on Phase 2 (once directories are layers, targets are
nearly mechanical); do it last or not at all — §2C has the honest tradeoffs.

Every phase ends with the full verification drill (§3.8) and leaves the tree green.

---

## 1. Current architecture, assessed

### 1.1 Map

| Directory | Files | Lines | Role | Layer (actual) |
|---|---|---|---|---|
| Geometry | 11 | 2,817 | Path/Mesh values, morphs, SVG parsing, shapes, **plus** Plane/plotting | **mixed L1 + L3.5** |
| Algebra | 7 | 1,611 | Rational, Expression, parser, CAS, Equation moves | L0 (pure leaf) |
| Animation | 10 | 1,380 | currency type, blueprints, clips, timeline, tracks, effects | L3 |
| Typesetting | 8 | 1,259 | TrueType + MathJax-SVG parsing **plus** TextEntity/GlyphSlice | **mixed L1 + L3.5** |
| Scene | 9 | 1,227 | Scene, camera(s), snapshot seam, Engine | L3 (hub) |
| Story | 3 | 1,203 | slide partitioning, player, transitions | L4 |
| WASM/Web | 10 | 1,177 | browser runtimes, loaders, input bindings | L5 (`#if os(WASI)`) |
| WASM/Render | 4 | 1,035 | WebGPU renderer, uploader, WGSL | L5 (`#if os(WASI)`) |
| ECS | 7 | 771 | Entity, ComponentSet, Group, System, Layout, Updater | L2 |
| Equation | 5 | 744 | token entities, equation game | L4 |
| Interaction | 3 | 679 | parallel clip layer, drag state machine | L4 |
| Math | 8 | 678 | Real/TypeAtlas, quaternion/matrix, easing, color, **plus** `Unit` | **mixed L0 + L3** |
| Physics | 3 | 451 | Hamiltonian bodies, SDF contacts | L4 |
| Input | 2 | 259 | event enums, swipe recognizer | L4 (tiny) |

The dependency scan (reference-level, comments included) confirms the layer diagram:

```
L0  Algebra (touches nothing — not even Real)     Math (Real, quat/matrix, easing, color)
L1  Geometry-values (Path/Mesh/morphs/SVG)        Typesetting-parsers (Font, MathSVG, TagScanner)
L2  ECS object model (Entity, Component, Group, System, Updater, Layout)
L3  Animation ⇄ Scene (mutually coupled by design: tracks take `in scene:`)  + snapshot seam
L3.5 entity kinds: shapes, TextEntity/GlyphSlice, MeshEntity, Plane/plotting, annotations
L4  Input/Interaction · Story · Physics · Equation(= Algebra + Typesetting + Interaction)
L5  WASM/Render (consumes SceneSnapshot only) · WASM/Web (drives Engine/Scene/Story)
```

Notable clean seams that already exist and must survive any redesign:

- **`SceneSnapshot` + `RenderBackend`** (Scene/Snapshot.swift) — the renderer is a dumb
  consumer; host tests assert snapshots. WASM/Render references *only* this seam.
- **Algebra** is a zero-dependency pure library — the scan shows no `Scene`, `Entity`, or
  even `Real` reference. It is already target-shaped.
- **The track contract** (Tracks.swift): `begin` idempotent / `apply` pure in t /
  `rewind` — uniformly honored by every track I read, including the structural ones.

### 1.2 Load-bearing decisions — explicitly preserved

This redesign treats the following as **constraints, not defects** (source: CLAUDE.md,
memory of user decisions, and the code):

- Whole mutable graph `@MainActor` over a Sendable value layer; `Component` deliberately
  not Sendable; `Entity.id` monotonic `UInt64`; no Foundation in the core.
- `Animation` as the currency type; chained descriptors accumulate as `AnimationPair`s;
  `add` consumes pair ids, `play` filters them.
- **Write/draw/erase/highlight/shake stay static `Animation` factories** (user decision
  2026-06-11; existentials can't see statics through `any Animatable`).
- **No implicit grouping** of separate `move(to: Unit)` calls (user decision 2026-06-11);
  grouped moves stay explicit via the `Group(…)` bag spelling.
- Normalized `strokeWidth` (1 = 10 % of the frame's longest side), resolved in
  `Scene.snapshot()` — stays the default behavior.
- Scrub contract: systems and interactions are *not* replayed by seeks; interaction
  effects persist across scrubs.
- Single `import Physica` for consumers (any target split hides behind a re-exporting
  umbrella).
- The perf stance: every leaf class `final`, `@_transparent` libm shims, `borrowing` on
  the audited hot paths only, `consuming`/`sending` deliberately unused.
- Restitution = min(A, B); physics entities as scene roots; the 3×-frame physics cull.

### 1.3 Findings

**a. Taxonomy drift** *(motivates Phase 2)*
- `Math/Unit.swift` is scene-relative placement (camera-frame anchoring) — L3 code in the
  L0 directory.
- `Geometry/` spans pure values (Path.swift, PathFlatten.swift, Mesh.swift, morphs,
  SVGPath.swift) and the full chart stack (Plane.swift 454, SampledEntities.swift 441,
  PlottingTracks.swift 166, Annotations.swift 186) plus the shape entities.
- `Typesetting/` spans the pure parsers (Font.swift 310, Font+cmap, ByteReader, MathSVG,
  TagScanner, Affine2) and the scene-coupled TextEntity.swift/GlyphSlice.swift (which
  define blueprints/tracks — animation-layer code).
- `Animation/` mixes the machinery (Animation, Blueprints, Clip, Timeline, Tracks,
  ValueTracks, StructuralTracks) with one-off effects (Highlight, Shake, SaveState).
- `Input/` (259 lines) is a satellite of `Interaction/` — the split predates the drag
  coordinator; nothing else consumes Input alone.
- Naming: `Algebra/Equation.swift` (the math object) vs `Equation/` (the token-entity UI)
  — two different "Equation" concepts one keystroke apart.

**b. Scene membership is encoded twice and the copies disagree** *(motivates 4a)*
- Membership truth #1: reachability through `scene.entities` (what render/hit-test use).
- Membership truth #2: the `entity.scene` weak pointer.
- They desync: `Scene.attach` sets the pointer recursively for group children
  (Scene.swift:106), but `Scene.detach` nils **only the root's** pointer
  (Scene.swift:83) — children of a detached group keep a dangling `scene`.
- `AddEntitiesTrack.begin` decides "already present" by pointer comparison
  (`$0.scene !== scene`, StructuralTracks.swift:30). Consequences:
  - Add a plane child directly (`scene.add(plane.grid)`) *before* adding the plane → the
    child becomes a root; adding the plane later renders it twice. This is the documented
    "never `scene.add` a plane child you also `.draw`" trap — a symptom, not a law.
  - Re-adding anything whose ancestor was detached by a slide clear is silently filtered
    out (stale pointer says "already there").
- `Group.addChild` must carry a guard comment about *not* wiping scene pointers for
  transient bags (Group.swift:31-33) — more dual-encoding tax.

**c. Plotting entities are half-coupled to their Plane** *(motivates 4b)*
- `Graph`/`VectorField`/`Streamlines` hold a **live** `plane` reference used every
  rebuild — `Graph.renderPath` clips against `plane.localPoint(…)` *now*
  (SampledEntities.swift:63-67), `value(at:)`/`point(at:)` read plane scale *now* —
  but copy the plane's transform **once** at creation
  (`transform = plane.worldTransform`, SampledEntities.swift:55).
- Coupled for math, decoupled for placement. Failure modes:
  - Move the plane after sampling → graphs stay behind (the documented "position the
    plane before sampling; group explicitly to move together").
  - `plane.size(…)` after sampling → `unitScale` changes, the graph's *clip band and
    annotation math* now use the new scale while its `lines` keep the old one —
    silently inconsistent geometry (the docs say "resize before sampling" but nothing
    enforces or even asserts it).
- Function samplers are not stored, so the plane can never re-derive a graph after a
  rescale even though it knows its own new scale.

**d. Camera `move(to:)` drags z** *(motivates 4c)*
- `scene.frame.move(to: 6.i)` runs the generic `MoveBlueprint` → destination z = 0 →
  camera z animates 10 → 0 (degenerate framing). `FocusMoveBlueprint` already does the
  right thing ("Keep the camera's own z", SceneCamera.swift:134-139). CLAUDE.md works
  around it ("prefer `shift`/`zoom`"). The camera proxy should make the wrong thing
  inexpressible instead.

**e. Public-surface sprawl** *(motivates Phase 3)*
- ~900 `public`/`open` declarations (Geometry 182, Scene 125, ECS 119, Math 88, …) for a
  framework with three in-repo consumers and a README that documents a much smaller API.
- Everything added during development defaulted to `public`; there has never been a
  curation pass. Internal machinery that leaks today includes track/blueprint plumbing,
  parser internals, and snapshot sub-structs consumers never touch. (Counts are
  grep-level; the exact demotion list is compiler-derived in Phase 3.)

**f. Hot-path and per-frame µ-warts** *(motivates Phase 1)*
- `Scene.snapshot()`'s `collect` builds an `indexPath` string per entity per frame and
  never uses it (Snapshot.swift:164-170, 282-289) — dead allocation on the hottest path.
- `Timeline.advance` calls `startTime(of: activeIndex)` (an O(clips) loop,
  Timeline.swift:150-156) every frame, and `duration` re-reduces all clips on every
  call — `StoryPlayer`/playback UI read it per frame. A long story (hundreds of clips)
  pays O(n) per frame for values that only change on `enqueue`. Cache cumulative starts,
  invalidate on enqueue.
- `Engine.tick` re-reads `backend.aspectRatio` and re-assigns `scene.viewportAspect`
  every frame for every binding (Engine.swift:52) — harmless, but a change-check is free.

**g. Oversized files** *(motivates Phase 1 splits)*
- SlideTransition.swift 464 (four transition families + their tracks in one file),
  Plane.swift 454, SampledEntities.swift 441 (four entity types + factories + re-plot
  animations), StoryPlayer.swift 412, WebGPURenderer.swift 444, StoryRuntime.swift 410.
  None is *wrong*; all are past the point where a seam would help navigation and diffs.

**h. Docs are one refactor behind the tree** *(folded into Phase 2)*
- README "Layout" still shows `Sources/Example0/` and `Sources/PhysicaDemo/App.swift`;
  the tree now has `Sources/PhysicaDemo/{Example0,Example1}` and no top-level Example0.
- CLAUDE.md's wasm build commands use `--product PhysicaDemo`; `Package.swift` no longer
  defines that product (implicit executables are `Example0`/`Example1`/`StoryStudio`).
- CLAUDE.md's big-picture section still describes the pre-reorg target layout.

---

## 2. The redesign

### Pillar A — In-place re-layering (Phases 1–3)

**Goal:** directories *are* the layers; every file sits where its dependencies say; the
public surface is the intended API and nothing else. No behavior change, no API break
for anything the repo uses.

**Target tree** (moves marked →, splits marked ✂):

```
Sources/Physica/
  Math/            TypeAtlas, Sugar, Quaternion, Matrix4, Color, Easing, Interpolatable
                   (Unit.swift → Scene/)
  Algebra/         unchanged (already a pure leaf)
  Geometry/        Path, PathFlatten, PathMorph, SVGPath, Mesh, MeshMorph   — values only
  Typesetting/     Font, Font+cmap, ByteReader, MathSVG, TagScanner, Affine2 — parsers only
  ECS/             Entity, Component, Components, Group, System, Updater, Layout
  Animation/       Animation, Blueprints, Clip, Timeline, Tracks, ValueTracks,
                   StructuralTracks
    Effects/       Highlight, Shake, SaveState
  Scene/           Scene (+Story/+Interactions/+HitTest), Camera, SceneCamera, Snapshot,
                   Engine, ClipComposer, Unit
  Entities/        Shapes (PathEntity, Circle, …, Arrow, Wall), MeshEntity*, Annotations,
                   TextEntity, GlyphSlice           ← the scene-coupled entity kinds
  Plotting/        Plane, Graph ✂, VectorField ✂, Streamlines ✂, PlottingTracks
  Interaction/     Input.swift →, SwipeRecognizer →, DragComponents, DragCoordinator,
                   InteractionRunner                ← Input/ folds in
  Story/           Story, StoryPlayer, Transitions/ ✂ (one file per family: Fade, Zoom,
                   Push, Morph + the shared arrival-track protocol)
  Physics/         unchanged
  Equation/        unchanged content (optional rename, see Open Questions)
  WASM/            unchanged (Render/ + Web/)
```

\* wherever `MeshEntity` currently lives (Shapes or Mesh file) — it moves with the
entity kinds.

Rules that make this stick (enforced by the Phase 5 split if adopted, by review until):
Geometry/Typesetting/Algebra/Math never name `Entity`/`Scene`; Entities/Plotting may
depend down on everything above; only Scene/ produces snapshots.

**File splits (Phase 1, before any move so history stays readable):**
- SampledEntities.swift ✂ → Graph.swift, VectorField.swift, Streamlines.swift,
  PlaneFactories.swift (the `Plane` extension + re-plot animations).
- SlideTransition.swift ✂ → Transitions/{SlideTransition, FadeTransition, ZoomTransition,
  PushTransition, MorphTransition}.swift.
- Plane.swift stays one file (it is one type), but `AxisOptions` gets its own file.

**µ-fixes (Phase 1):**
- Drop the dead `indexPath` plumbing from `Scene.snapshot()`'s collect.
- `Timeline`: cache cumulative clip start times + total duration; invalidate on
  `enqueue`. (Also gives `locate` binary search for free — seeks during scroll-scrub
  are O(log n).)
- `Engine.tick`: only write `viewportAspect` when it changed.

**Public-surface curation (Phase 3), compiler-driven:** demote everything to `internal`
in one directory at a time; re-publicize exactly what `Tests/`, `PhysicaDemo/`,
`StoryStudio/` (host-typecheck + wasm build) demand; diff the result against the
README's documented API and re-publicize the documented-but-unused remainder
deliberately. Deliverable: an `API.md` listing the curated surface, so future additions
default to internal.

**Docs sync (Phase 2 exit):** README layout section, CLAUDE.md big-picture + build
commands (`--product Example1` etc.), Documentation.docc pages that reference paths.

### Pillar B — API footgun redesigns (Phase 4)

**B1 — one truth for scene membership** *(4a; enables 4b)*
- `Scene.detach` recurses like `attach` already does (children's pointers clear with the
  root's); `retire` unchanged.
- `AddEntitiesTrack.begin` decides presence by **graph reachability** (walk `parent` to a
  root, check root ∈ `scene.entities`) instead of pointer identity. `Scene.insert` gains
  the same guard: inserting an entity whose ancestor is already in the scene is a no-op
  (with a debug assertion so authors learn).
- Net effect: `scene.add(plane.labels)` / `.draw(plane.grid)` become order-independent
  and double-render-proof; the CLAUDE.md trap paragraph gets deleted rather than
  documented harder. Transient bags keep working — a bag never joins the scene, so
  reachability for its members is decided by their real roots, which also deletes the
  guard subtlety in `Group.addChild`.
- Tests: the existing scrub/story suites already cover re-insert ordering; add cases for
  child-first add, add-then-parent-add, slide-clear + re-add.

**B2 — plotting entities become children of their Plane** *(4b; depends on 4a)*
- `plane.graph(of:)/plot/field/streamlines` create the entity **as a plane child**
  (identity transform; `lines` are already plane-local — rendering is pixel-identical).
  `transform = plane.worldTransform` and the "copy at creation" semantics disappear.
- Moving/scaling the plane moves everything on it — `Group(plane, graph).move(…)`
  becomes unnecessary (still works). `move(to: Unit)` on the plane pins the whole board
  by its real union bounds.
- `plane.size(…)` re-derives children: function graphs store their sampler
  (`@escaping`), data plots re-map stored data-space samples, fields/streamlines
  re-sample from stored generators. The "resize before sampling" rule dies. (Function
  storage makes `graph(of:)`'s closure escaping — the one signature change.)
- Reveal flows unchanged: `.draw(graph)` works whether or not the plane is on the board
  yet (B1 makes the auto-add reachability-aware); `scene.add(plane)` reveals the board
  including whatever it carries, painter's order = child order (board under curves —
  today's implicit convention, now structural).
- Breaking changes, exhaustively: ① `graph.point(at:)`/`value(at:)` unchanged (they
  already answer in world/data space); ② code that relied on graphs *not* following the
  plane must detach explicitly (`plane.removeChild(graph)`) — repo scan shows no such
  use; ③ `graph(of:)` closure becomes `@escaping`.
- Tests: plane-move-carries-graph, size-after-sampling re-derivation, draw-before-add
  ordering, existing plotting suites stay green with unchanged numbers.

**B3 — camera moves preserve z** *(4c)*
- `SceneCamera` overrides `move(to: Position)` (and the shared blueprint path) to a
  z-preserving move — same one-liner `FocusMoveBlueprint` already uses. `shift` and
  explicit 3-component moves keep full control (`move(to: Position(x, y, 8))` with a
  non-zero z still honors it: preserve-z applies only when the destination z equals 0
  and the camera z doesn't — the one ambiguous case — or, simpler and predictable:
  a dedicated `CameraMoveBlueprint` that always keeps current z unless the caller uses
  `moveZ`/`shift`). Decision point flagged in Open Questions; default = always-preserve
  with a `frame.move(to:keepingZ: false)` escape hatch.
- CLAUDE.md's "prefer shift/zoom" caveat gets deleted.

**Deliberately NOT redesigned** (documented as settled in §1.2): static animation
factories, no-implicit-grouping, normalized strokeWidth default (a `.world(_:)` stroke
unit is listed as an open question, not a plan), scrub-freeze for systems/interactions,
`Group`'s transient-bag idiom (B1 removes its sharp edge; the dual role itself is
useful and stays).

### Pillar C — SwiftPM target split (Phase 5, optional)

**Target DAG** (each = one Phase-2 directory or a small union):

```
PhysicaMath ← PhysicaGeometry, PhysicaTypesetting, PhysicaKernel, …
PhysicaAlgebra                       (no deps at all)
PhysicaKernel   = ECS + Animation + Scene + Entities   (mutually coupled → one target)
PhysicaPlotting = Plotting           (Kernel + Geometry + Typesetting)
PhysicaInteraction, PhysicaStory, PhysicaPhysics       (Kernel)
PhysicaEquation = Equation           (Kernel + Algebra + Typesetting + Interaction)
PhysicaWeb      = WASM               (everything; sole JSKit dependency, still
                                      `.when(platforms: [.wasi])`)
Physica         = umbrella: `@_exported import` of all of the above
```

- Consumers keep `import Physica` byte-for-byte (preserves the June single-target
  decision's *purpose* — one import, one product — while making the layers structural).
- Cross-target internal access uses the `package` modifier (Scene.insert/detach,
  Timeline.enqueue, carriedThisSlide, bakeClip are the known cases; the compiler finds
  the rest).
- Perf notes: the `@_transparent` Real shims are already public (fine cross-module);
  `final` devirtualization is per-module and unaffected; enable Cross-Module
  Optimization for release wasm builds and **diff the four bundle sizes + the smoke
  timeline output** before/after as the acceptance gate.
- Honest costs: Package.swift grows ~8 stanzas; `package`-access churn lands in the
  kernel seams; slower cold builds (more module graph); every future cross-cutting
  change touches more boundaries. Value: import hygiene enforced by the compiler
  (a Geometry file physically cannot reach Scene), per-layer testability, and Algebra/
  Typesetting become reusable elsewhere as-is.
- Recommendation: **do it only if the compiler-enforced boundary is worth those costs to
  you** — after Phases 1–4 the conventions are much easier to hold by review; a solo
  author with tests may reasonably stop at Phase 3.

---

## 3. Phase plan

Each phase is a separate session-sized unit, lands green, and ends with §3.8.

1. **Quiet wins** — µ-fixes (f), file splits (g). No moves, no renames.
2. **Re-layer** — `git mv` per §2A tree; fold Input/ into Interaction/; docs sync (h).
   Pure mechanical; the compiler proves nothing changed (single module, no code edits
   beyond the moved-file headers' comments).
3. **Surface curation** — per-directory demotion sweep; produce `API.md`.
4. **Semantics** — 4a membership truth → 4b plane children → 4c camera z. Each with its
   test list from §2B, its CLAUDE.md paragraph rewritten, and a wasm visual check.
5. **Target split** — per §2C, gated on bundle-size + smoke diffs.

**3.8 Verification drill (every phase):** `swift test` (full host suite) · wasm builds
for all three executables (`--product Example1`, `Example0`, `StoryStudio`) ·
`bun scripts/smoke.mjs` byte-identical timeline · `bun scripts/smoke-studio.mjs` ·
headless-Chrome screenshots for anything touching WASM/ or rendering-adjacent semantics
(4b) · CLAUDE.md/README updated in the same commit that invalidates them.

---

## 4. Open questions (answer when picking phases)

1. **Equation naming** — rename `Equation/` → `EquationGame/` (dir only, types keep
   their names) to kill the Algebra.Equation collision? Cheap during Phase 2, noisy
   after. *(Default if unanswered: rename dir only.)*
2. **Camera z rule (4c)** — always-preserve-z with an explicit opt-out, or
   preserve-only-when-destination-z-is-0? *(Default: always-preserve + opt-out.)*
3. **Stroke units** — add `.stroke(width: .world(0.2))` alongside the normalized
   default? Not planned; say the word and it joins 4c. *(Default: no.)*
4. **Phase 5** — in or out? *(Default: deferred until 1–4 have landed and been lived
   with.)*
