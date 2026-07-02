# Algebra & the Equation Game

An exact CAS and a drag-the-term-across-the-equals interaction built on it.

## Overview

`Sources/Physica/Algebra/` is a dependency-free, host-tested computer algebra
core, and `Sources/Physica/EquationGame/` renders it as draggable tokens. Together
they make the equation a thing the viewer manipulates, with the algebra checked
exactly rather than numerically.

## The algebra core

- ``Rational`` — exact rational arithmetic (no floating point in the algebra).
- ``Expression`` — an `indirect enum` AST, including a `.vector` case that plain
  CAS libraries lack.
- `Expression(parsing:)` — a byte-level TeX-ish parser: `\vec`, `\frac`,
  `\cdot`, the `\theta`-class symbols, `F_x` subscripts, and juxtaposition →
  implicit multiply.
- A simplifier (n-ary flatten → canonical sort → exact fold → like-term collect)
  that **never auto-distributes**.
- ``Equation`` — the moves a viewer can make.

### The move rule

Dragging a token across `=` applies its **inverse to both sides** (the Equalynx
rule): an addend subtracts from both sides; a numeric coefficient divides both
(exact). A same-side drop folds. `applying(dropped, asRole: .factor, to:)`
multiplies both sides and returns a `.choice([factored, distributed])` when those
differ — which the UI raises as chips. `matches()` is simplifier-based, so `2x`
matches `x·2`.

### Projection

``ComponentTable`` (parsed eagerly from author markup) lets
`Equation.projected(onto:components:)` substitute each vector for its scalar
component:

```
\vec F = m\vec g + \vec T
  → x:  F_x = T\cos\theta
  → y:  0   = mg + T\sin\theta
```

See ``Projection``.

## Rendering equations as tokens

Each token is a ``TextEntity`` carrying a `TokenComponent` (its `DisplayToken`
plus a move address). Glyphs come from a **synchronous** glyph provider — MathJax
`tex2svg` is sync after one `load()`:

- `FontTokenGlyphProvider` renders `token.value` from a ``Font``.
- `MathJaxTokenProvider` renders per-token SVG (cached) on the web.
- `StubTokenGlyphProvider` emits unit boxes for tests.

`MathSVG.measuredGlyphs` is the baseline-relative variant (it parses the root
`vertical-align: -Nex`) so a row's tokens share a baseline. ``EquationEntity``
stacks ``EquationRow``s and x-aligns every `=` on the first row's anchor; only
the last row is editable.

## The game

``EquationGame`` installs **one** ``DropTargetComponent`` on the equation. On
drop it:

1. reads the move address off the dragged proxy's `TokenComponent`,
2. picks the side by the drop's x versus the `=`'s world x,
3. runs `movingTerm` / `applying` / `projected`.

A `.resolved` outcome appends a row; a `.choice` raises chips
(`drag.isEnabled = false` while they're up). Reaching the `goal` (by `matches`)
highlights the result and fires `onWin`. ``GlyphSlice/makeLiteral(_:)` clones a
slice into a draggable ``LiteralEntity`` that follows the source's world center
until grabbed, and ``PlaceholderEquationEntity`` is a drop target that matches
its `target` via `matches()`.

## See also

- <doc:Interactions> — the drag/drop/tap machinery the game is built on.
- <doc:StoryMode> — where these games typically live, pause-independent.
