// WebpageShell — the facade's embedded page chrome. The shipping HTML shells
// are deliberately plain (one bare `<canvas id="main">` and the module import),
// so the facade injects everything the runtimes look up — the scene-host
// wrapper, the playback bar, the story spacer track / HUD / caption band — and
// the stylesheet that lays it out, before `WebRuntime`/`StoryRuntime` run.
// Same philosophy as `ArticleDOM.ensureStyle`: the page carries no CSS; the
// bundle does. Idempotent — a second mount finds the marker ids and skips.

import PhysicaFoundation

#if os(WASI)
import JavaScriptKit

@MainActor
enum WebpageShell {
    // MARK: Entry points

    /// The animation-mode shell: centered canvas + playback bar (the DOM
    /// `WebRuntime`'s `PlaybackControls`/`DebugOverlay` expect).
    static func injectSceneShell() {
        guard let dom = JSObject.global.document.object else { return }
        ensureStyle(dom, id: "physica-shell-style", css: baseCSS + sceneCSS)
        if dom.getElementById!("scene-host").object != nil { return }

        let canvas = adoptedCanvas(dom)

        var main = el(dom, "main")

        var host = el(dom, "div")
        host.className = .string("scene-host")
        host.id = .string("scene-host")
        _ = host.appendChild(canvas)

        var replay = el(dom, "button")
        replay.id = .string("replay")
        replay.className = .string("replay")
        replay.hidden = .boolean(true)
        replay.textContent = .string("↻ Replay")
        _ = host.appendChild(replay)
        _ = main.appendChild(host)

        var playback = el(dom, "div")
        playback.className = .string("playback")
        playback.id = .string("playback")

        var button = el(dom, "button")
        button.id = .string("playpause")
        button.textContent = .string("Pause")
        _ = playback.appendChild(button)

        var slider = el(dom, "input")
        slider.id = .string("scrub")
        _ = slider.setAttribute("type", "range")
        _ = slider.setAttribute("min", "0")
        _ = slider.setAttribute("max", "1000")
        _ = slider.setAttribute("value", "0")
        _ = slider.setAttribute("step", "1")
        _ = playback.appendChild(slider)

        var time = el(dom, "span")
        time.className = .string("time")
        time.id = .string("time")
        time.textContent = .string("0.00 / 0.00 s")
        _ = playback.appendChild(time)
        _ = main.appendChild(playback)

        appendHint(
            dom, to: main, className: "hint",
            text: "Hold Shift for entity indices, ⌥+Shift for draggable elements. Drag the slider to scrub."
        )
        _ = dom.body.appendChild(main)
    }

    /// The story-mode shell: pinned canvas + HUD + caption band + action row +
    /// the scroll spacer track (`StoryRuntime`'s scroll-scrub source).
    static func injectStoryShell() {
        guard let dom = JSObject.global.document.object else { return }
        ensureStyle(dom, id: "physica-shell-style", css: baseCSS + storyCSS)
        if dom.getElementById!("story-track").object != nil { return }

        let canvas = adoptedCanvas(dom)

        var story = el(dom, "div")
        story.id = .string("story")

        var pin = el(dom, "div")
        pin.id = .string("story-pin")

        var host = el(dom, "div")
        host.className = .string("scene-host")
        host.id = .string("scene-host")
        _ = host.appendChild(canvas)
        _ = pin.appendChild(host)

        for id in ["story-hud", "story-caption", "story-actions"] {
            var node = el(dom, "div")
            node.id = .string(id)
            _ = pin.appendChild(node)
        }
        _ = story.appendChild(pin)

        var track = el(dom, "div")
        track.id = .string("story-track")
        _ = story.appendChild(track)
        _ = dom.body.appendChild(story)

        appendHint(
            dom, to: JSObject.global.document.body, className: "story-hint",
            text: "Scroll to scrub · Space play/pause · ↑/↓ slides · ←/→ steps · Shift for indices"
        )
    }

    // MARK: Helpers

    /// Injects `css` as a `<style id=…>` in `<head>` once (idempotent).
    static func ensureStyle(_ dom: JSObject, id: String, css: String) {
        if dom.getElementById!(id).object != nil { return }
        var style = dom.createElement!("style")
        style.id = .string(id)
        style.textContent = .string(css)
        var head = dom.head
        if head.object != nil {
            _ = head.appendChild(style)
        } else {
            var root = dom.documentElement
            if root.object != nil { _ = root.appendChild(style) }
        }
    }

    /// The page's `<canvas id="main">`, detached for re-parenting into the
    /// shell (appendChild moves it); created fresh when the page has none.
    private static func adoptedCanvas(_ dom: JSObject) -> JSValue {
        let existing = dom.getElementById!("main")
        if existing.object != nil { return existing }
        var canvas = dom.createElement!("canvas")
        canvas.id = .string("main")
        return canvas
    }

    private static func el(_ dom: JSObject, _ tag: String) -> JSValue {
        dom.createElement!(tag)
    }

    private static func appendHint(_ dom: JSObject, to parent: JSValue, className: String, text: String) {
        var parent = parent
        var hint = el(dom, "p")
        hint.className = .string(className)
        hint.textContent = .string(text)
        _ = parent.appendChild(hint)
    }

    // MARK: Stylesheets (adapted from the retired example HTML shells)

    private static let baseCSS = """
    :root { color-scheme: dark; }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: #101014;
      color: #e8e8ec;
      font: 14px/1.4 -apple-system, system-ui, sans-serif;
    }
    .scene-host { position: relative; overflow: hidden; }
    canvas#main {
      display: block;
      width: 100%;
      background: #16161c;
      -webkit-user-select: none;
      user-select: none;
      -webkit-touch-callout: none;
    }
    .overlay-label {
      position: absolute;
      z-index: 2;
      transform: translate(-50%, -50%);
      padding: 1px 5px;
      border-radius: 4px;
      background: rgba(91, 140, 255, 0.85);
      color: #fff;
      font: 11px/1.5 ui-monospace, monospace;
      pointer-events: none;
      white-space: nowrap;
    }
    .overlay-label-drag        { background: rgba(255, 170, 64, 0.92);  color: #221604; }
    .overlay-label-drop        { background: rgba(120, 230, 130, 0.92); color: #06210a; }
    .overlay-label-tap         { background: rgba(200, 150, 255, 0.92); color: #1a0a2a; }
    .overlay-label-doubleClick { background: rgba(255, 130, 190, 0.92); color: #2a0617; }
    .overlay-label-hover       { background: rgba(120, 220, 240, 0.92); color: #04222a; }
    .overlay-drop-area {
      position: absolute;
      z-index: 1;
      box-sizing: border-box;
      border: 1.5px dashed rgba(120, 230, 130, 0.9);
      background: rgba(120, 230, 130, 0.12);
      border-radius: 6px;
      pointer-events: none;
    }
    """

    private static let sceneCSS = """
    main { max-width: 960px; margin: 0 auto; padding: 16px; }
    canvas#main { aspect-ratio: 16 / 10; border-radius: 8px; touch-action: none; }
    .playback { display: flex; gap: 10px; align-items: center; padding: 10px 2px; }
    .playback button {
      width: 72px;
      padding: 6px 0;
      border: 1px solid #3a3a44;
      border-radius: 6px;
      background: #1e1e26;
      color: inherit;
      cursor: pointer;
    }
    .playback button:hover { background: #2a2a34; }
    .playback input[type="range"] { flex: 1; accent-color: #5b8cff; }
    .playback .time { min-width: 96px; text-align: right; font-variant-numeric: tabular-nums; color: #9a9aa6; }
    .hint { color: #62626e; padding: 4px 2px; }
    .replay {
      position: absolute;
      left: 50%;
      top: 50%;
      transform: translate(-50%, -50%);
      padding: 12px 28px;
      border: 1px solid #3a3a44;
      border-radius: 10px;
      background: rgba(30, 30, 38, 0.9);
      color: #e8e8ec;
      font: inherit;
      font-size: 16px;
      cursor: pointer;
    }
    .replay:hover { background: rgba(42, 42, 52, 0.95); }
    .replay[hidden] { display: none; }
    """

    private static let storyCSS = """
    html { scroll-snap-type: y proximity; }
    #story { position: relative; }
    #story-pin {
      position: sticky;
      top: 0;
      height: 100vh;
      display: flex;
      flex-direction: column;
    }
    .scene-host { flex: 1; }
    canvas#main { height: 100%; background: #101014; touch-action: pan-y; }
    #story-hud {
      position: absolute;
      top: 14px;
      left: 16px;
      padding: 6px 12px;
      border-radius: 8px;
      background: rgba(22, 22, 28, 0.7);
      font: 13px/1.4 ui-monospace, monospace;
      letter-spacing: 0.02em;
      color: #cfd8e6;
      pointer-events: none;
    }
    #story-caption {
      position: absolute;
      left: 50%;
      bottom: 64px;
      transform: translateX(-50%);
      max-width: min(82%, 720px);
      padding: 10px 18px;
      border-radius: 10px;
      background: rgba(12, 12, 16, 0.72);
      color: #eef0f4;
      font: 17px/1.5 -apple-system, system-ui, sans-serif;
      text-align: center;
      pointer-events: none;
      opacity: 0;
      transition: opacity 0.25s ease;
    }
    #story-caption.show { opacity: 1; }
    #story-actions {
      position: absolute;
      bottom: 16px;
      left: 16px;
      display: flex;
      gap: 8px;
    }
    #story-actions button {
      padding: 7px 14px;
      border: 1px solid #3a3a4499;
      border-radius: 8px;
      background: rgba(28, 28, 36, 0.85);
      color: #cfd8e6;
      cursor: pointer;
      font: inherit;
    }
    #story-actions button:hover { background: rgba(42, 42, 54, 0.95); }
    .story-hint {
      position: fixed;
      bottom: 16px;
      right: 16px;
      color: #5a5f6b;
      font-size: 12px;
      pointer-events: none;
    }
    """
}

#endif
