# Physica public API inventory

*Maintained by hand since the Phase-3 curation pass (2026-07-02, REDESIGN.md). The
rule going forward: **new symbols default to `internal`**; a symbol becomes `public`
only when a demo, StoryStudio, or the documented API story needs it, and it should
then also appear in `Documentation.docc/Documentation.md`'s Topics. Members of the
types below are public by that type's design; internal machinery (blueprints,
tracks, parsers' internals, the WASM renderer) is not exported.*

Constraints discovered by the compiler, so nobody re-litigates them:

- `FlattenedContour` stays public — `PathMorph.Matched.from/to` (public morph-data
  API) are `[[FlattenedContour]]`-shaped, and `Path.flattened()` is public with it.
- `StubTokenGlyphProvider` stays public — Example2's `Example2.swift` uses it as the
  no-font fallback provider.
- `DragOptions` stays public — `DragCoordinator.options` is a public var.
- The **six open base classes** (`Entity`, `Group`, `Layout`, `PathEntity`,
  `SampledPathEntity`, `MeshEntity`) stay `open` deliberately; every other class is
  `final` (devirtualization — see CLAUDE.md's performance conventions).

Demoted to internal in the curation pass: `SwipeRecognizer`, `SwipeDirection`
(only `StoryRuntime` consumes them), `UpdaterComponent.Entry` + `.entries` (the
public surface is `entity.updater` / `addUpdater` / `bind` / `removeUpdater`),
`TextComponent.glyphFactors` (snapshot-internal math).

Phase-5 (target split) addenda:

- Consumers still write **one `import Physica`** — the umbrella target
  `@_exported`s all eleven layer targets. Nothing below changes spelling.
- New public API: `GroupAnchored` (an entity that attaches to a host group
  instead of rooting — how plots ride their plane), `PositionedGlyph` is now a
  top-level Typesetting type (`TextComponent.PositionedGlyph` remains as a
  typealias), and `Transform`/`Bounds` moved to PhysicaMath/PhysicaGeometry
  (same names, same members).
- The cross-target seams use `package` access — visible inside this package,
  invisible to external consumers: `Scene.insert/detach/retire/addItems/`
  `playItems/enqueueSlideClear/resetSlideCarry/carriedThisSlide`,
  `Timeline.enqueue`, `AnimationClip.init`, the track `progress(at:easing:)`
  helper, `name(of:)`, `AddEntitiesTrack`/`RemoveEntityTrack`, `FadeBlueprint`,
  `Entity.scene`'s setter, `Layout.placementBounds`, `TextEntity.init(glyphs:)`,
  `GlyphSlice.text/.range`, `SIMD2.distance()`.

## Math (pure)

`Real` (Float on wasm / Double on host), `Position`, `TimeInterval`, `Color`,
`Quaternion`, `Matrix4`, `Easing`, `Interpolatable`, the `Real.sin/cos/…` libm
shims, and the `1.i / 2.s` sugar.

## Algebra (pure leaf — no other dependencies)

`Rational`, `Expression` (+ `BinaryOperator`, `UnaryOperator`), `Equation`
(+ `EquationSide`, `TermRole`, `TokenAddress`, `AlgebraOutcome`/`AlgebraChoice`,
`ExpressionOutcome`, `MoveOutcome`), `Simplifier` surface via `Expression`,
`ProjectionAxis`, `ComponentTable`, `DisplayToken` (+ `Kind`), `AlgebraError`.

## Geometry (pure values)

`Path` (+ `Contour`, `Segment`), `FlattenedContour`, `PathMorph` (+ `Matched`),
`Mesh`, `MeshMorph` (+ `Matched`), `Shading`, `SVGPathError`.

## Typesetting (pure parsers)

`Font` (+ `Glyph`, `FontError`), `MathSVG` (+ `MathSVGError`).

## ECS (object model)

`Entity`, `Group`, `HasHierarchy`, `Layout` / `Row` / `Column` / `Grid`,
`Component`, `ComponentSet`, `System`, `EntityQuery`, `SceneUpdateContext`,
`UpdaterComponent` (via `entity.updater` / `bind`), `Animatable`, `HasTransform`,
`Transform`, `TransformComponent`, `Bounds`, `RenderStyleComponent`,
`PathTexture`, `StrokeCap`.

## Animation

`Animation`, `AnimationPair`, `AnimationBuilder`, `AnimationBlueprint` (extension
seam), `AnimationTrackProtocol` (extension seam — honor begin/apply/rewind),
`AnimationClip`, `Timeline` (+ `TimelineEvent`, `TimelineState`), `Keyframe`,
`SavedStateComponent` (via `saveState()`/`restoreState()`).

## Scene & rendering seam

`Scene`, `Engine`, `Camera` (+ `Projection`), `SceneCamera`, `ClipComposer`,
`Unit`, and the renderer-facing value seam: `SceneSnapshot`, `RenderPrimitive`,
`PathPrimitive` (+ `Contour`), `PathStyle`, `MeshDraw`, `CameraState`,
`SceneBackground`, `DebugLabel`, `InteractionKind`, `RenderBackend`.

## Entity kinds

`PathEntity` (+ `PathComponent`), `Circle`, `Rectangle`, `Triangle`, `Line`,
`Arrow`, `Wall` (+ `Face`), `TextEntity` (+ `TextComponent`, `PositionedGlyph`),
`GlyphSlice`, `MeshEntity` (+ `ModelComponent`), and the annotations
`SurroundingRectangle`, `Underline`, `Callout`, `Pointer`, `Spotlight`.

## Plotting

`Plane`, `AxisOptions`, `SampledPathEntity`, `Graph`, `VectorField`,
`Streamlines`.

## Interaction & input

`InputEvent`, `PointerKind`, `PointerState`, `DragCoordinator`, `DragOptions`,
`DraggableComponent`, `DropTargetComponent`, `DropResolution`, `DragPayload`,
`TapComponent`, `DoubleTapComponent`, `HoverComponent`, `InteractionRunner`
(+ `Handle`), `InterruptionPolicy`.

## Story

`Story`, `Slide`, `StoryOptions`, `StoryPlayer` (+ `StoryEvent`, `StoryState`),
`SlideTransition`.

## Physics

`HamiltonianSystem`, `PhysicsShape`, `PhysicsBodyComponent` (+ `Mode`),
`PhysicsMotionComponent`, `SignedDistanceField`.

## Equation game

`EquationEntity`, `EquationRow`, `EquationGame`, `EquationStyle`,
`PlaceholderEquationEntity`, `LiteralEntity` (+ `LiteralKind`),
`TokenGlyphProvider`, `FontTokenGlyphProvider`, `StubTokenGlyphProvider`,
`TokenComponent`, `TokenGlyphRun`.

## WASM (browser-only, `#if os(WASI)`)

`WebRuntime`, `StoryRuntime`, `FontLoader`, `MathJaxLoader`,
`MathJaxTokenProvider`. Everything else in `WASM/` (renderer, uploader, shaders,
input bindings, overlay) is internal behind `WebRuntime.run`/`StoryRuntime.run`.
