# ``Physica``

A pure-Swift-6 framework for explorable physics: a RealityKit-style ECS, a
Manim-style scripted animation API, WebGPU rendering in the browser, and
Hamiltonian rigid-body physics.

## Overview

Physica is one library built around a single idea: **everything is an
``Animation``**. Entity methods like `move`, `shift`, `scale`, `rotate`,
`color`, `fade`, and `morph` don't mutate anything — they return deferred
descriptors. `scene.add`, `scene.play`, and `scene.wait` enqueue clips on one
append-only ``Timeline`` and *also* return an ``Animation``, so the whole API
composes. Because the timeline is append-only, playback is **scrub-safe**:
`seek(t)` replays and rewinds clips deterministically, making the same script a
movie you can scroll through frame by frame.

```swift
let bob = Circle().move(to: .top)        // descriptor — nothing happens yet
scene.add(bob)                           // 0-duration clip on the timeline
scene.play(bob.move(to: .bottom), for: 2.s)
scene.play(.write(TextEntity("g", font: font)))
```

The framework is **dependency-free on the host**: everything outside
`Sources/Physica/WASM/` never imports Foundation or JavaScriptKit, builds and
tests on macOS, and is where essentially all logic lives. The `WASM/` subtree is
the WebGPU renderer and browser glue (every file `#if os(WASI)`), linking
JavaScriptKit only when building for wasm. The seam between them is one value
type — `Scene.snapshot()` produces a ``SceneSnapshot`` of flattened world-space
primitives, and the ``RenderBackend`` protocol consumes it. Host tests assert on
snapshots; the renderer is a dumb consumer.

The numeric layer is generic over `Real` (`Float` on wasm, `Double` on macOS),
so write numeric code against it and keep assertions tolerance-based.

### Where to start

- New to the framework? Read <doc:GettingStarted>.
- Want to understand the animation model deeply? Read <doc:ScriptedAnimation>.
- Building an interactive lesson? See <doc:Interactions>, <doc:StoryMode>, and
  <doc:EquationGame>.
- Plotting functions, fields, or flows? See <doc:Plotting>.
- Touching concurrency or adding a track type? Read <doc:Concurrency>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:ScriptedAnimation>
- <doc:Concurrency>

### Scene & rendering

- ``Scene``
- ``Engine``
- ``Camera``
- ``SceneCamera``
- ``SceneSnapshot``
- ``SceneBackground``
- ``RenderBackend``
- ``SceneUpdateContext``
- ``WebRuntime``

### Entities & components

- ``Entity``
- ``Group``
- ``Component``
- ``ComponentSet``
- ``System``
- ``EntityQuery``
- ``UpdaterComponent``
- ``TransformComponent``
- ``ModelComponent``
- ``RenderStyleComponent``

### Layout

- ``Layout``
- ``Row``
- ``Column``
- ``Grid``

### Animation

- ``Animation``
- ``Animatable``
- ``AnimationBlueprint``
- ``AnimationClip``
- ``AnimationPair``
- ``ClipComposer``
- ``Timeline``
- ``Easing``
- ``Keyframe``
- ``Interpolatable``
- ``Transform``
- ``Unit``

### Shapes & vector graphics

- ``Path``
- ``PathEntity``
- ``Circle``
- ``Rectangle``
- ``Triangle``
- ``Line``
- ``Arrow``
- ``Wall``
- ``SurroundingRectangle``
- ``Underline``
- ``Callout``
- ``Spotlight``
- ``PathMorph``
- ``PathStyle``
- ``StrokeCap``
- ``PathTexture``

### Text & math

- ``TextEntity``
- ``Font``
- ``Glyph``
- ``GlyphSlice``
- ``PositionedGlyph``
- ``MathSVG``
- ``MathJaxLoader``

### 3D meshes

- ``Mesh``
- ``MeshEntity``
- ``MeshMorph``
- ``MeshDraw``
- ``Shading``

### Plotting

- <doc:Plotting>
- ``Plane``
- ``Graph``
- ``VectorField``
- ``Streamlines``
- ``AxisOptions``

### Physics

- ``HamiltonianSystem``
- ``PhysicsShape``
- ``PhysicsBodyComponent``
- ``PhysicsMotionComponent``
- ``SignedDistanceField``

### Interaction & input

- <doc:Interactions>
- ``DragCoordinator``
- ``DraggableComponent``
- ``DropTargetComponent``
- ``TapComponent``
- ``DoubleTapComponent``
- ``HoverComponent``
- ``InteractionRunner``
- ``InterruptionPolicy``
- ``InputEvent``

### Story mode

- <doc:StoryMode>
- ``Story``
- ``Slide``
- ``StoryPlayer``
- ``SlideTransition``
- ``StoryRuntime``

### Algebra & the equation game

- <doc:EquationGame>
- ``Expression``
- ``Rational``
- ``Equation``
- ``EquationEntity``
- ``EquationGame``
- ``PlaceholderEquationEntity``
- ``LiteralEntity``
- ``Projection``
- ``ComponentTable``

### Math primitives

- ``Color``
- ``Quaternion``
- ``Matrix4``
- ``Bounds``
