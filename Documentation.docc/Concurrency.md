# Concurrency Model

The isolation rules that hold everywhere in Physica, and the per-frame update
order that follows from them.

## Overview

Physica is split into two layers:

- A **mutable object graph** — ``Entity``, ``Scene``, ``Timeline``,
  ``Animation``, ``Engine``, ``System``, and the web glue — that is entirely
  `@MainActor`.
- A pure **`Sendable` value layer** beneath it — `Transform`, ``Path``,
  ``Mesh``, ``Color``, snapshots, and the event enums.

Several conventions exist *because* of this split, and they're load-bearing:

- ``Component`` is deliberately **not** `Sendable` — `UpdaterComponent` stores
  `@MainActor` closures.
- `Entity.id` is a `nonisolated let UInt64` from a monotonic counter
  (deterministic for tests, no UUID/Foundation); `==` and `hash` use the id only.
- `@MainActor` classes expose `var debugString: String` instead of conforming to
  `CustomDebugStringConvertible` (which is nonisolated). Tests assert on
  `debugString`, formatted with a hand-rolled fixed-decimal `fmt()` so Float and
  Double hosts print identically.
- AsyncStreams (`Timeline.eventStream()`, `Scene.inputStream()`) carry `Sendable`
  enums only.

## The numeric layer

`Math/TypeAtlas.swift` defines `Real` — `Float` on wasm, `Double` on macOS —
along with `Position = SIMD3<Real>` and the libm shims (`Real.sin`, etc., because
Apple's simd module doesn't exist on WASI, which is also why ``Quaternion`` and
``Matrix4`` are hand-rolled). Write numeric code against `Real` and keep test
assertions tolerance-based so both hosts pass.

## Per-frame update order

`Scene.update` runs, in order:

1. **paused-gated:** `timeline.advance` → systems
2. `interactions.advance` — **always**, outside the gate
3. layouts
4. updaters

Updaters (`entity.updater = { ... }` or `entity.bind(\.end, to: bob, \.position)`)
also run once after every `seek`.

The crucial detail is step 2: interactions and drag run *outside* the paused
gate, so they keep working while the timeline rests paused — which is exactly the
state story mode sits in at every step boundary. See <doc:Interactions>.

## Scrubbing vs. systems

During `seek`, **all systems are suspended** and one updater pass runs
afterward. So:

- Animation state replays and rewinds deterministically (the timeline is
  append-only; every track honors `begin`/`apply`/`rewind`).
- **System-driven state — pendulum, physics — intentionally freezes during a
  scrub and resumes live afterward.** It is not replayed.

This is a deliberate contract, not a limitation to work around. Story mode never
`resume()`s, so in a story the scripted clips must carry all motion; live
systems are for the free-play, non-story timeline.

## Performance levers (intentional, meant to stay)

These are applied once across the tree and shouldn't be casually undone:

- **Every leaf class is `final`** (devirtualization + inlinability). Only six
  bases are deliberately `open`: ``Entity``, ``Group``, ``Layout``,
  ``PathEntity``, `SampledPathEntity`, and ``MeshEntity``.
- The `Real` / libm shims are `@_transparent` (inline at every call site, no
  Float/Double wrapper frame).
- Hot array builders `reserveCapacity` from a known count.
- `borrowing` rides only the per-frame hot paths where a *heap-backed* value is
  read-only (the geometry uploader's pack/append paths and mesh resampling),
  eliding per-primitive retain/release. It is deliberately **not** on
  trivially-copyable structs (`Transform`/`Matrix4`/`Quaternion`/`Color`), where
  WMO already elides the stack copy.

`consuming` and `sending` are evaluated-but-unused on purpose: the value graph
keeps canonical data in blueprints and hands copies to tracks (the source
outlives the call), and the concurrency model already obviates `sending` —
AsyncStreams carry `Sendable` enums and JSClosure bodies use `assumeIsolated`,
so no non-Sendable value crosses an isolation boundary.

## See also

- <doc:ScriptedAnimation> — the scrub-safe timeline contract in full.
- <doc:GettingStarted> — building and testing on the macOS host.
