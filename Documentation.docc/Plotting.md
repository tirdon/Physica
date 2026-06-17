# Plotting

Coordinate planes, function graphs, vector fields, and streamlines — where the
data itself is the animatable.

## Overview

A ``Plane`` is a ``Group`` that assembles a coordinate board: a minor `subgrid`
under the major `grid`, `axes` built from real ``Arrow`` entities (double-headed,
so a tip sits at both terminals), `ticks`, and — when a font is supplied —
`labels`. Because the axes are real arrows, you can grab and adjust their
`start` / `end` / `headLength` directly.

```swift
let plane = Plane(x: -5...5, y: -3...3, gridStep: 1, font: font)
plane.size(8, aspect: 0.625)            // rescale BEFORE sampling
scene.add(plane, plane.labels)          // labels are a Group you reveal explicitly
```

``Group`` has an `Int` subscript for children in add order, so
`plane.xLabels[0].color(.red)` and `plane.axes[0] === plane.xAxis` both work, and
trap out-of-range like `Array`. ``AxisOptions`` (a top-level struct — nested
types in `@MainActor` classes inherit isolation) holds overhang, tick length, tip
length, and label settings; assigning `plane.axis` rebuilds the board in place.

> Important: `plane.point(x, y)` maps data → world, and the plotting helpers copy
> the plane's transform at creation. **Position the plane before sampling.**

## Graphs, fields, and flows

These return **standalone entities** sampled in plane space — reveal them with
`scene.add` or `.draw`; never `scene.add` a plane child you also `.draw`:

```swift
let wave  = plane.graph(of: { sin($0) })
let field = plane.field { p in SIMD2(-p.y, p.x) }
let flow  = plane.streamlines { p in SIMD2(1, p.x) }
let scatter = plane.plot(points)
```

To move a plane and its graph together, wrap them: `Group(plane, wave).move(...)`.

### Reading the live curve

``Graph/value(at:)`` and ``Graph/point(at:)`` read the **live** polyline —
mid-morph included — so annotations can track an animating curve:

```swift
dot.updater = { $0.position = wave.point(at: 1.2) }
```

## Data is the animatable

Each helper's plotting method returns an ``Animation``, and the **data** is what
interpolates:

- ``Graph`` and ``Streamlines`` lerp sample polylines via a polyline-morph track
  (index-paired, arc-length resampled to the larger count — no contour sorting,
  unlike path morphs, which would scramble many-line bundles).
- ``VectorField`` lerps its `vectors` and rebuilds arrows per frame, so heads
  point true mid-morph.

Topology stays constant by construction: function graphs re-sample the same xs,
streamlines re-integrate the same seeds (RK2, step clamped to `gridStep/2`, lines
freeze at the board edge), and fields always emit shaft + head contours even when
degenerate. Graph y-values clamp to the y range; non-finite samples pin to the
top edge; arrow length saturates against a creation-time reference magnitude.

## See also

- ``Plane``, ``Graph``, ``VectorField``, ``Streamlines``, ``AxisOptions``
- <doc:ScriptedAnimation> — how the returned animations schedule and scrub.
