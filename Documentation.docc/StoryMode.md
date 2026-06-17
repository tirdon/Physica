# Story Mode

Turn one scrubbable timeline into a scroll-driven, slide-partitioned lesson.

## Overview

``Story`` partitions a single ``Timeline`` into slides without ever forking it.
``Story/slide(_:transition:_:)`` snapshots `timeline.duration` before and after
its content to record a `[startTime, endTime]` range plus the step boundaries
inside it. The result is one scrubbable movie with chapter markers — the same
script is both a movie and a slideshow.

```swift
let story = Story(scene: scene)

story.slide("Free body", transition: .fade) { s in
    scene.play(.write(title))
    scene.play(.draw(diagram))
    s.carry(diagram)                 // keep this past the slide boundary
}

story.slide("Projection") { s in
    scene.play(.write(equation))
}

story.action("Solve") { scene in    // a button that animates in parallel
    scene.interact(.highlight(answer))
}
```

## Slide-scoped content

Content is **slide-scoped by default**: a slide's own-introduced entities
auto-clear when the viewer advances to the next slide (a deferred zero-duration
clear track, computed as *introduced − carried − in-slide removals*).

- ``Slide/carry(_:)`` keeps specific content past the slide (it persists onward
  until an explicit clear).
- ``Slide/clear(_:)`` drops content mid-slide.
- Globals (`scene.add`ed before or between slides) are never in any slide's own
  set, so they persist untracked.
- The **last slide never auto-clears** — its board stays.

A ``SlideTransition`` describes how the camera moves between slides; because the
camera is itself an entity (`scene.frame`), those transitions are ordinary
scrubbable clips.

## Navigation

``StoryPlayer`` is the **single writer to the playhead**. Story mode never
`resume()`s the scene, so systems stay frozen and the scripted clips carry all
motion. Navigation rides one precomputed beat list (time + slide + step) built
from the slides:

- `nextStep` / `previousStep` move ±1 beat.
- `nextSlide` / `previousSlide` jump between step-0 beats.
- Scroll maps to `scrub(...)`; arrows tween forward (the camera transition
  plays) and seek back instantly.

Every move funnels through one private `apply(time:)` that seeks, dedupes
(`seekEpsilon`), and runs the slide-change hook — `interactions.interruptAll`,
`drag.cancelActive`, and a `.slideChanged` event. This is why interactions and
drag are pause-independent (see <doc:Interactions>).

## In the browser

``StoryRuntime/run(engine:story:)`` mirrors `WebRuntime` but adds per-slide
scroll spacers, four-arrow keyboard nav (with `preventDefault`), a horizontal
swipe recognizer for touch step-nav, action buttons, and a RAF loop that ignores
scroll input while a tween drives the scrollbar (echo-safe). It logs the story
first, so a GPU-free smoke run still prints it.

`story.html` is a separate page (`#story-pin` sticky element, spacer track, and
`globalThis.physicaStory = true` set before init). `index.html` and the smoke
test are untouched — `App.boot` branches on `physicaStory` to pick the story
runtime versus the plain ``WebRuntime``.

## See also

- <doc:ScriptedAnimation> — the timeline contract story mode partitions.
- <doc:Interactions> — `interact`, drag, and why they survive a paused timeline.
