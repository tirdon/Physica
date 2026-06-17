# Scripted Animation

How the animation currency type, clips, and the scrub-safe timeline fit together.

## Overview

The central design decision in Physica is that **``Animation`` is the currency
type**. Entity methods are deferred *descriptors* — they build blueprints and
mutate nothing:

```swift
let a = star.opacity(0.8).shift(-1.j)   // carries BOTH blueprints, applies neither
```

Chained calls accumulate into ``AnimationPair`` blueprints. ``Scene/add(_:)``
marks pair ids consumed and `play` filters them, which is why a stored handle
can be re-animated without re-applying its original move:

```swift
let bob = Circle().move(to: p)   // the move is "consumed" by add
scene.add(bob)
scene.play(bob.move(to: q))      // only the NEW move plays
```

`scene.add`, `scene.play`, `scene.wait`, and `scene.pause(System.self)` all
enqueue clips *and* return an ``Animation``, so everything composes.

## Play forms

There are four ways to play, covering increasingly fine timing control:

```swift
scene.play(a, b, for: 2.s, easing: .easeInOut)   // variadic, shared duration
scene.play(group: a1, a2)                         // one clip, each keeps its own offset
scene.play(3.s) { clip in /* builder */ }         // result-builder clip
scene.play { clip in                              // composer: per-animation timing
    clip.add(anim, for: 1.s, offset: 0.5.s)
}
```

**Duration precedence:** `play(for:)` > `animation.duration` > blueprint default
(1 s).

### Static factories

`write` / `draw` / `erase` / `highlight` are static ``Animation`` factories, not
entity methods — they resolve through a concrete `play(_: Animation...)`
overload because leading-dot syntax can't see statics through `any Animatable`:

```swift
scene.play(.write(title))      // introducesTarget → auto-adds the entity
scene.play(.draw(shape))
scene.play(.erase(title))      // same blueprint reversed + removesTargetAtEnd
scene.play(.highlight(entity)) // transient neon border chase, leaves nothing behind
```

Write/draw auto-add their target (no `scene.add` first); erase additionally
drops a remove track at the clip's end. Both are scrub-safe — rewinding un-adds
or re-inserts at the original root index, so painter's order survives.

### Glyph slices and gradients

Text and formula glyph ranges return a ``GlyphSlice`` whose `color`,
`color(mix:)`, `fade(to:)`, and `opacity` are deferred animations targeting the
parent entity:

```swift
title[0].color(.red)
title[1..<4].color(mix: [.blue, .green])     // multi-stop ramp across the slice
text.color(mix: [.red, .orange, .yellow])    // whole-text gradient
```

Per-glyph overrides live on ``PositionedGlyph``, beat the entity style, and
rewind to their prior value exactly (a nil override comes back as nil).

### Save & restore

``Animatable`` and ``Group`` bags support Manim's save/restore. Save is a
0-duration clip that captures transforms *at that point of the timeline*;
restore animates back to them. Both are scrub-safe.

```swift
bob.saveState()              // capture (usually mid-motion)
scene.play(bob.move(to: q))
scene.play(bob.restoreState())
```

## The scrub-safe timeline contract

The ``Timeline`` is an append-only clip history, and `seek(t)` is deterministic:
forward seeks apply intermediate clips at their end time; backward seeks call
each track's `rewind()` in reverse, so entities added by an `add` clip disappear
when you scrub before it.

Every track implements three methods:

- `begin(in:)` — idempotent start-value capture.
- `apply(at:in:)` — pure in `t`.
- `rewind()` — restore pre-clip state.

> Important: Any new track type must honor `begin`/`apply`/`rewind`, and must
> snap exactly to endpoints at `t ≤ 0` / `t ≥ 1`, or scrubbing breaks. See
> `PathMorphTrack` for the canonical implementation.

**System-driven state freezes during a scrub.** During `seek` all systems are
suspended and a single updater pass runs afterward. Pendulum and physics state
is *not* replayed — it resumes live after the scrub. This is intentional; see
<doc:Concurrency> for the per-frame update order.

## Moving entities together

``Unit`` moves pin each entity's own bounds independently — separate `move(to:)`
calls in one `play` do not group. To move several entities as a rigid unit, wrap
them in a transient ``Group``:

```swift
Group(pivot, string, bob).move(to: .bottom)   // pins the union, shifts every member equally
```

The group pins the union of the members' bounds and applies one shared delta, so
a pendulum keeps its string length. The group never joins the scene — it's a
bag.

## See also

- <doc:Interactions> — `interact` reuses clips but plays them *now*, outside the
  scrub history.
- <doc:StoryMode> — partitioning one scrubbable timeline into slides.
