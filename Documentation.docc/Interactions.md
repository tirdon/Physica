# Interactions & Drag

Run animations in parallel and let the viewer drag, drop, tap, and hover —
even while the timeline rests paused.

## Overview

Story mode rests paused at every step boundary, which is exactly when a viewer
interacts. So Physica has two subsystems that run *outside* the paused gate:
``InteractionRunner`` (parallel animations) and ``DragCoordinator``
(event-driven pointer handling). Neither participates in the scrub history.

## Parallel interactions

``Scene/interact(_:)`` has the same surface as `play` — moves, write/draw/erase,
``highlight``, ``shake`` — but plays the clip **now, in parallel**, and *not* in
the timeline. `seek` never touches it, and structural effects it introduces (a
triggered `.write`'s entity, an appended equation row) persist across scrubs:

```swift
scene.interact(.highlight(token))                 // fire-and-forget, parallel
scene.interact(chip.move(to: slot))
```

An ``InterruptionPolicy`` controls what happens if an interaction is interrupted:

- `.complete` (default) jumps to the end — game results must land.
- `.cancel` rewinds.

`interruptAll` fires on slide change. Because `interact` and `play` share the
same clip-baking path, they filter consumed pairs identically (only `add`
inserts entities).

## Drag, drop, tap, hover

``DragCoordinator`` is driven from `Scene.dispatch`, not a registry ``System``
(systems skip while paused). It's a state machine: press → (past `tapSlop`) drag
→ drop; a release within slop is a tap. Hit-testing walks the scene in
painter's order and **last-painted wins**, matching the renderer.

Behavior is attached via non-Sendable components that hold `@MainActor`
closures:

| Component | Purpose |
| --- | --- |
| ``DraggableComponent`` | `payload`, optional `makeDragProxy` ghost, `snapsBack`, `onTap` / `onDragBegan` |
| ``DropTargetComponent`` | `accepts` / `onDrop` → `DropResolution`, `onHoverChanged` |
| ``TapComponent`` | chips — works even while `drag.isEnabled == false` |
| ``HoverComponent`` | bare-pointer enter/leave (mouse/pen only) |
| ``DoubleTapComponent`` | `onDoubleTap`; `highlightSelf()` is the prebuilt "double-tap me to neon-loop my bounds" handler |

```swift
chip.components[DraggableComponent.self] = DraggableComponent(
    payload: .token(address),
    makeDragProxy: { $0.cloneGhost() },   // source stays put; a ghost follows the pointer
    snapsBack: true
)
slot.components[DropTargetComponent.self] = DropTargetComponent(
    accepts: { $0.payload.matches(target) },
    onDrop:  { _ in .accepted }
)
```

A rejected or off-target drop snaps home via an interaction (`.complete`);
`cancelActive` is an instant restore used on slide change. Double-click rides a
dedicated `InputEvent.doubleClick(Position)` — the browser does the timing via
DOM `dblclick`, so the core carries no clock.

``shake(_:)`` is a static ``Animation`` factory (damped horizontal wobble,
scrub-safe, exact at both ends), like ``highlight``.

## Where this runs in the frame

Per-frame order in `Scene.update` is:

1. paused-gated: `timeline.advance` → systems
2. `interactions.advance` — **always**, outside the gate
3. layouts
4. updaters

Interactions and drag therefore keep working while the timeline rests paused.
See <doc:Concurrency> for the full ordering and the reasoning behind it.

## See also

- <doc:EquationGame> — drag-a-term-across-the-equals game built on these pieces.
- <doc:StoryMode> — where pause-independent interaction matters most.
