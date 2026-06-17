// StageOverlay — direct manipulation on the canvas (WASI only).
//
// Owns its own pointer listeners on the canvas (separate from the framework's
// InputBindings, which is inert for editor elements — they carry no Draggable
// components). Translates pointer events to normalized-viewport points and hands
// them to the app, which hit-tests, selects, and drags. Also owns the DOM
// selection box drawn over the selected element's world bounds.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
final class StageOverlay {
    private let canvas: JSValue
    private var host: JSValue = .undefined
    private var selectionBoxes: [JSValue] = []       // a pool, one box per selected element
    private var guideLines: [JSValue] = []           // a pool, ⌥-drag alignment guides (0…2 lines)
    private var idLabels: [JSValue] = []             // a pool, one id tag per element (hold-⌥ overlay)
    private var radial: JSValue = .undefined         // ⌥-click overlap picker (a full-stage scrim + ring)
    private var radialItems: [(id: Int, colorHex: UInt32)] = []   // every element under the ⌥-click
    private var radialCenter = SIMD2<Real>(0, 0)     // normalized-viewport click point (to re-place on expand)
    private var radialExpanded = false               // false → show a few + "+N"; true → the whole ring
    private static let radialMaxChips = 6            // chips shown before collapsing the rest into "+N"
    private var editor: JSValue = .undefined         // inline text/math editor (<input>)
    private var editing = false
    private var editCommit: (@MainActor (String) -> Void)?
    private var closures: [JSClosure] = []
    private var pressed = false
    private weak var app: StudioApp?

    init(canvasID: String, hostID: String, app: StudioApp) {
        self.app = app
        let dom = JSObject.global.document
        self.canvas = dom.getElementById(canvasID)

        if let document = dom.object {
            let host = document.getElementById!(hostID)
            if host.object != nil {
                self.host = host

                // The inline editor: one reused <textarea> shown over a text/math
                // element while editing (double-click), hidden otherwise. A textarea
                // (not <input>) so Shift+Enter can insert a newline.
                var input = document.createElement!("textarea")
                input.className = .string("stage-text-editor")
                input.rows = .number(1)
                input.spellcheck = .boolean(false)
                _ = input.setAttribute("autocomplete", "off")
                _ = input.setAttribute("style", "display:none")
                _ = host.appendChild(input)
                self.editor = input

                // The ⌥-click overlap picker: one reused full-stage scrim that the
                // ring of element chips mounts into. One delegated pointerdown handler
                // (read further down) reads the picked id off the clicked chip — so
                // re-showing the picker never allocates per-item JSClosures we'd have
                // to tear down mid-callback.
                let scrim = document.createElement!("div")
                scrim.className = .string("stage-radial-scrim")
                _ = scrim.setAttribute("style", "display:none")
                _ = host.appendChild(scrim)
                self.radial = scrim
            }
        }

        listen("pointerdown") { [weak self] e in self?.down(e) }
        listen("pointermove") { [weak self] e in self?.move(e) }
        listen("pointerup")   { [weak self] e in self?.up(e) }
        listen("pointercancel") { [weak self] _ in self?.pressed = false }
        listen("dblclick")    { [weak self] e in self?.dbl(e) }

        if editor.object != nil {
            let onKey = JSClosure { [weak self] args in
                let e = args.first ?? .undefined
                MainActor.assumeIsolated { self?.editorKey(e) }
                return .undefined
            }
            let onBlur = JSClosure { [weak self] _ in
                MainActor.assumeIsolated { self?.endEdit(commit: true) }
                return .undefined
            }
            let onInput = JSClosure { [weak self] _ in
                MainActor.assumeIsolated { self?.autoGrow() }
                return .undefined
            }
            closures.append(onKey)
            closures.append(onBlur)
            closures.append(onInput)
            _ = editor.addEventListener("keydown", onKey)
            _ = editor.addEventListener("blur", onBlur)
            _ = editor.addEventListener("input", onInput)
        }

        if radial.object != nil {
            // One handler for the whole picker (event delegation): a pointerdown on a
            // chip carries its `data-radial-id`; anywhere else on the scrim dismisses.
            let onRadial = JSClosure { [weak self] args in
                let e = args.first ?? .undefined
                MainActor.assumeIsolated { self?.radialPointerDown(e) }
                return .undefined
            }
            // Hovering the "+N" overflow chip blooms the ring (mouse); a press handles
            // touch — both in `radialPointerDown`/`radialPointerOver`.
            let onRadialOver = JSClosure { [weak self] args in
                let e = args.first ?? .undefined
                MainActor.assumeIsolated { self?.radialPointerOver(e) }
                return .undefined
            }
            closures.append(onRadial)
            closures.append(onRadialOver)
            _ = radial.addEventListener("pointerdown", onRadial)
            _ = radial.addEventListener("pointerover", onRadialOver)
        }
    }

    private func listen(_ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
        let c = JSClosure { args in
            let e = args.first ?? .undefined
            MainActor.assumeIsolated { handler(e) }
            return .undefined
        }
        closures.append(c)
        _ = canvas.addEventListener(event, c)
    }

    private func down(_ event: JSValue) {
        let alt = event.altKey.boolean ?? false
        // Track move/up for every press: ⌥ now arms a *deferred* gesture — the app
        // decides snap-drag vs. overlap picker on pointer-up — so the move/up stream
        // is needed even with ⌥ held (it was suppressed when ⌥-click was modal).
        pressed = true
        let meta = (event.metaKey.boolean ?? false) || (event.ctrlKey.boolean ?? false)
        app?.stagePointerDown(
            viewport: viewport(event),
            shift: event.shiftKey.boolean ?? false,
            meta: meta,
            alt: alt
        )
    }
    private func move(_ event: JSValue) {
        guard pressed else { return }
        app?.stagePointerDrag(viewport: viewport(event))
    }
    private func up(_ event: JSValue) {
        guard pressed else { return }
        pressed = false
        app?.stagePointerUp(viewport: viewport(event))
    }
    private func dbl(_ event: JSValue) {
        app?.stageDoubleClick(viewport: viewport(event))
    }

    /// Pointer event → normalized viewport point (0,0 top-left … 1,1 bottom-right).
    private func viewport(_ event: JSValue) -> SIMD2<Real> {
        let rect = canvas.getBoundingClientRect()
        let w = Swift.max(rect.width.number ?? 1, 1)
        let h = Swift.max(rect.height.number ?? 1, 1)
        let nx = ((event.clientX.number ?? 0) - (rect.left.number ?? 0)) / w
        let ny = ((event.clientY.number ?? 0) - (rect.top.number ?? 0)) / h
        return SIMD2(Real(nx), Real(ny))
    }

    /// The canvas's current pixel size — the app derives the world-space snap
    /// threshold from a fixed pixel feel with it (so the snap holds at any zoom).
    var canvasPixelSize: SIMD2<Real> {
        let rect = canvas.getBoundingClientRect()
        return SIMD2(Real(Swift.max(rect.width.number ?? 1, 1)), Real(Swift.max(rect.height.number ?? 1, 1)))
    }

    /// Draws one selection box per `rects` entry (over its world-space bounds),
    /// growing the box pool as needed and hiding any boxes beyond the count.
    func showSelections(_ rects: [(min: SIMD2<Real>, max: SIMD2<Real>)], scene: Scene) {
        guard host.object != nil else { return }
        while selectionBoxes.count < rects.count { selectionBoxes.append(makeSelectionBox()) }
        let rect = canvas.getBoundingClientRect()
        let w = rect.width.number ?? 1
        let h = rect.height.number ?? 1
        for (i, box) in selectionBoxes.enumerated() {
            guard i < rects.count else { _ = box.setAttribute("style", "display:none"); continue }
            // Top-left and bottom-right corners in world space → normalized viewport.
            let topLeft = scene.viewportPosition(world: Position(rects[i].min.x, rects[i].max.y, 0))
            let botRight = scene.viewportPosition(world: Position(rects[i].max.x, rects[i].min.y, 0))
            let left = Double(topLeft.x) * w
            let top = Double(topLeft.y) * h
            let width = Double(botRight.x - topLeft.x) * w
            let height = Double(botRight.y - topLeft.y) * h
            _ = box.setAttribute(
                "style",
                "display:block;left:\(left)px;top:\(top)px;width:\(width)px;height:\(height)px"
            )
        }
    }

    func hideSelection() {
        for box in selectionBoxes { _ = box.setAttribute("style", "display:none") }
    }

    private func makeSelectionBox() -> JSValue {
        guard let document = JSObject.global.document.object else { return .undefined }
        var box = document.createElement!("div")
        box.className = .string("stage-selection")
        _ = box.setAttribute("style", "display:none")
        _ = host.appendChild(box)
        return box
    }

    // MARK: Alignment guides (⌥-drag smart guides)

    /// Draws the ⌥-drag alignment guides (0…2 lines) over the canvas, mapping each
    /// world-space line through the same world→viewport→pixel chain the selection
    /// box uses. Screen-centre lines carry a distinct class from element-to-element
    /// ones; surplus lines from a prior frame are hidden.
    func showGuides(_ guides: [SnapGuide], scene: Scene) {
        guard host.object != nil else { return }
        while guideLines.count < guides.count { guideLines.append(makeGuide()) }
        let rect = canvas.getBoundingClientRect()
        let w = rect.width.number ?? 1
        let h = rect.height.number ?? 1
        for (i, line) in guideLines.enumerated() {
            guard i < guides.count else { _ = line.setAttribute("style", "display:none"); continue }
            let g = guides[i]
            line.className = .string(g.kind == .screenCenter ? "stage-guide stage-guide-screen" : "stage-guide")
            if g.axis == .vertical {
                let a = scene.viewportPosition(world: Position(g.position, g.start, 0))
                let b = scene.viewportPosition(world: Position(g.position, g.end, 0))
                let x = Double(a.x) * w
                let y0 = Double(Swift.min(a.y, b.y)) * h
                let y1 = Double(Swift.max(a.y, b.y)) * h
                _ = line.setAttribute(
                    "style", "display:block;left:\(x - 0.5)px;top:\(y0)px;width:1px;height:\(y1 - y0)px")
            } else {
                let a = scene.viewportPosition(world: Position(g.start, g.position, 0))
                let b = scene.viewportPosition(world: Position(g.end, g.position, 0))
                let y = Double(a.y) * h
                let x0 = Double(Swift.min(a.x, b.x)) * w
                let x1 = Double(Swift.max(a.x, b.x)) * w
                _ = line.setAttribute(
                    "style", "display:block;left:\(x0)px;top:\(y - 0.5)px;width:\(x1 - x0)px;height:1px")
            }
        }
    }

    /// Hides every alignment guide (drag end, or a non-snapping drag).
    func clearGuides() {
        for line in guideLines { _ = line.setAttribute("style", "display:none") }
    }

    private func makeGuide() -> JSValue {
        guard let document = JSObject.global.document.object else { return .undefined }
        let line = document.createElement!("div")
        line.className = .string("stage-guide")
        _ = line.setAttribute("style", "display:none")
        _ = host.appendChild(line)
        return line
    }

    // MARK: Element-id tags (hold-⌥ inspection overlay)

    /// Draws one id tag per entry, anchored at the top-left of its world bounds,
    /// reusing the selection boxes' world→viewport mapping. Off-frame entries (and
    /// any surplus tags from a prior, larger slide) are hidden.
    func showIDLabels(_ labels: [(id: Int, min: SIMD2<Real>, max: SIMD2<Real>)], scene: Scene) {
        guard host.object != nil else { return }
        while idLabels.count < labels.count { idLabels.append(makeIDLabel()) }
        let rect = canvas.getBoundingClientRect()
        let w = rect.width.number ?? 1
        let h = rect.height.number ?? 1
        for (i, tag) in idLabels.enumerated() {
            guard i < labels.count else { _ = tag.setAttribute("style", "display:none"); continue }
            let anchor = scene.viewportPosition(world: Position(labels[i].min.x, labels[i].max.y, 0))
            // Skip elements parked off the visible frame so their tags don't pile at the edge.
            guard anchor.x > -0.04, anchor.x < 1.04, anchor.y > -0.04, anchor.y < 1.04 else {
                _ = tag.setAttribute("style", "display:none"); continue
            }
            tag.textContent = .string("#\(labels[i].id)")
            let left = Double(anchor.x) * w
            let top = Double(anchor.y) * h
            _ = tag.setAttribute("style", "display:block;left:\(left)px;top:\(top)px")
        }
    }

    func hideIDLabels() {
        for tag in idLabels { _ = tag.setAttribute("style", "display:none") }
    }

    private func makeIDLabel() -> JSValue {
        guard let document = JSObject.global.document.object else { return .undefined }
        let tag = document.createElement!("div")
        tag.className = .string("stage-id-label")
        _ = tag.setAttribute("style", "display:none")
        _ = host.appendChild(tag)
        return tag
    }

    // MARK: ⌥-click overlap picker (radial menu)

    /// Raises the radial picker centered on `centerViewport` (normalized 0…1) over
    /// `items` (every element under the ⌥-click, topmost first). Few elements show as
    /// an arc of `#id` chips bowing toward the canvas centre; once there are more than
    /// fit, only the first `radialMaxChips` show plus one "+N" overflow chip (N hidden)
    /// that blooms to the whole ring on hover/press. The scrim covers the stage, so it's modal.
    func showRadialPicker(centerViewport: SIMD2<Real>, items: [(id: Int, colorHex: UInt32)]) {
        guard radial.object != nil else { return }
        radialItems = items
        radialCenter = centerViewport
        radialExpanded = false
        renderRadial()
        _ = radial.setAttribute("style", "display:block")
    }

    /// (Re)draws the hub + ring for the current `radialItems`/`radialExpanded` state.
    /// Chips carry no listeners — the scrim's delegated handlers read them — so a full
    /// `innerHTML` rebuild on expand is safe (no JSClosure churn).
    private func renderRadial() {
        guard radial.object != nil, let document = JSObject.global.document.object else { return }
        radial.innerHTML = .string("")

        let rect = canvas.getBoundingClientRect()
        let w = rect.width.number ?? 1
        let h = rect.height.number ?? 1
        let cx = Double(radialCenter.x) * w
        let cy = Double(radialCenter.y) * h

        // Center hub marks the click point.
        let hub = document.createElement!("div")
        hub.className = .string("stage-radial-hub")
        _ = hub.setAttribute("style", "left:\(cx)px;top:\(cy)px")
        _ = radial.appendChild(hub)

        // Collapsed unless expanded or it already fits: a few nearest chips + one "+N".
        let collapsed = !radialExpanded && radialItems.count > Self.radialMaxChips + 1
        let shown = collapsed ? Array(radialItems.prefix(Self.radialMaxChips)) : radialItems
        let slots = shown.count + (collapsed ? 1 : 0)

        // Layout follows the reference sketches: a few entities trace a partial arc —
        // an open "C", part of a circle — that widens with the count (2 → small
        // crescent, 5–7 → fuller C); only once the chips would wrap past a full turn
        // (8+, reachable by expanding "+N") do they spread evenly into a closed donut.
        // The arc is rotated to face the canvas centre — its chips fan toward the
        // middle with the opening toward the nearer edge — so they stay on-screen even
        // when you ⌥-click near a border. The radius grows with the slot count so
        // chips never crowd and the ring scales from crescent to big donut.
        let aimX = Real(w / 2 - cx), aimY = Real(h / 2 - cy)        // click → canvas centre
        let aim = (aimX == 0 && aimY == 0) ? -Real.pi / 2 : Real.atan2(aimY, aimX)
        let gap = Real.pi / 3.5         // ~51° between adjacent chips on a partial arc
        let full = slots >= 8           // a constant-gap arc would otherwise close past here
        let step = full ? Real.tau / Real(slots) : gap
        let radius = Real(Swift.min(150.0, Swift.max(58.0, 8.5 * Double(slots))))
        let first = full ? aim : aim - step * Real(slots - 1) / 2   // partial arc centred on the aim
        func place(_ node: JSValue, slot: Int, style: String) {
            let angle = first + step * Real(slot)
            let dx = Double(radius * Real.cos(angle)), dy = Double(radius * Real.sin(angle))
            let x = cx + dx, y = cy + dy
            // Bloom-from-hub: each chip animates (see `stage-radial-bloom`) from the hub
            // outward to (x,y); --fromx/--fromy translate it back onto the hub to start,
            // and --slot staggers the sweep so the ring opens rather than popping at once.
            _ = node.setAttribute(
                "style",
                "left:\(x)px;top:\(y)px;--fromx:\(-dx)px;--fromy:\(-dy)px;--slot:\(slot);\(style)"
            )
            _ = radial.appendChild(node)
        }

        for (i, item) in shown.enumerated() {
            let chip = document.createElement!("button")
            chip.className = .string("stage-radial-item")
            _ = chip.setAttribute("data-radial-id", "\(item.id)")
            chip.textContent = .string("#\(item.id)")   // id only — no name
            // Fill with the element's own colour (auto-contrasting text), so each chip
            // is colour-keyed to the canvas; the button is its own event target.
            place(chip, slot: i, style: "background:\(cssHex(item.colorHex));color:\(contrastHex(item.colorHex))")
        }
        if collapsed {
            let more = document.createElement!("button")
            more.className = .string("stage-radial-item stage-radial-more")
            _ = more.setAttribute("data-radial-more", "1")
            // Show how many elements are hidden ("+N") rather than a bare "…", so the
            // overflow chip preserves the total count; still blooms the ring on hover/press.
            more.textContent = .string("+\(radialItems.count - shown.count)")
            place(more, slot: shown.count, style: "")   // neutral fill from CSS
        }
    }

    /// Blooms the collapsed picker into the full ring (idempotent once expanded).
    private func expandRadial() {
        guard !radialExpanded else { return }
        radialExpanded = true
        renderRadial()
    }

    /// Tears the picker down (hidden + emptied). Safe to call when already closed.
    func hideRadialPicker() {
        guard radial.object != nil else { return }
        _ = radial.setAttribute("style", "display:none")
        radial.innerHTML = .string("")
        radialItems = []
        radialExpanded = false
    }

    /// Delegated scrim handler: the overflow ("+N") chip blooms the ring; an element
    /// chip's `data-radial-id` selects it; a press on the bare scrim/hub dismisses.
    private func radialPointerDown(_ event: JSValue) {
        _ = event.preventDefault()
        let target: JSValue = event.target
        if target.getAttribute("data-radial-more").string != nil { expandRadial(); return }
        let idString = target.getAttribute("data-radial-id").string
        hideRadialPicker()
        if let idString, let id = Int(idString) { app?.selectElement(id) }
    }

    /// Hovering the "+N" overflow chip blooms the ring (mouse path; touch uses the press above).
    private func radialPointerOver(_ event: JSValue) {
        guard !radialExpanded else { return }
        if event.target.getAttribute("data-radial-more").string != nil { expandRadial() }
    }

    /// Near-black or off-white — whichever reads on a `hex` fill (perceived luminance).
    private func contrastHex(_ hex: UInt32) -> String {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? "#0c130f" : "#eef4ee"
    }

    // MARK: Inline text editing

    /// True while the inline editor is open (the app commits it before starting a
    /// new canvas gesture).
    var isEditing: Bool { editing }

    /// Opens the inline editor over a world-space bounds, seeded with `text` in the
    /// element's colour, focused with its contents selected. `onCommit` fires with
    /// the final value on Enter or blur (a click away) — not on Escape.
    func beginEditing(
        text: String,
        worldMin: SIMD2<Real>, worldMax: SIMD2<Real>,
        colorHex: UInt32, scene: Scene,
        onCommit: @escaping @MainActor (String) -> Void
    ) {
        guard editor.object != nil else { return }
        editing = true
        editCommit = onCommit

        let rect = canvas.getBoundingClientRect()
        let w = rect.width.number ?? 1
        let h = rect.height.number ?? 1
        // Same world → canvas-pixel mapping the selection box uses.
        let topLeft = scene.viewportPosition(world: Position(worldMin.x, worldMax.y, 0))
        let botRight = scene.viewportPosition(world: Position(worldMax.x, worldMin.y, 0))
        let left = Double(topLeft.x) * w
        let top = Double(topLeft.y) * h
        let boxW = Double(botRight.x - topLeft.x) * w
        let boxH = Double(botRight.y - topLeft.y) * h

        // Track the on-stage glyph height so the field reads inline, clamped to a
        // comfortable range; pad the box a touch around the text.
        let fontPx = Swift.min(40, Swift.max(13, boxH))
        let padX = 6.0, padY = 4.0
        let width = Swift.max(boxW, 90) + padX * 2
        // Floor the box to the element's on-stage height so the editor's opaque
        // background fully masks the glyph underneath (autoGrow only ever *adds*
        // height for multi-line text; without this a tall glyph peeks out below).
        let minH = boxH + padY * 2

        editor.value = .string(text)
        _ = editor.setAttribute("style", [
            "display:block",
            "left:\(left - padX)px",
            "top:\(top - padY)px",
            "width:\(width)px",
            "min-height:\(minH)px",
            "font-size:\(fontPx)px",
            "color:\(cssHex(colorHex))",
        ].joined(separator: ";"))
        autoGrow()                 // fit the box height to the (possibly multi-line) text
        _ = editor.focus()
        _ = editor.select()
    }

    /// Commits and closes any open editor (no-op when not editing).
    func endEditing() { endEdit(commit: true) }

    private func editorKey(_ event: JSValue) {
        _ = event.stopPropagation()   // typing must not reach the window shortcuts
        switch event.key.string ?? "" {
        case "Enter":
            // Shift+Enter inserts a newline (textarea default); plain Enter commits.
            if event.shiftKey.boolean ?? false { break }
            _ = event.preventDefault(); endEdit(commit: true)
        case "Escape": _ = event.preventDefault(); endEdit(commit: false)
        default: break
        }
    }

    /// Grows the textarea to fit its content (so multi-line edits aren't clipped).
    private func autoGrow() {
        guard editor.object != nil else { return }
        editor.style.height = .string("auto")
        let scrollHeight = editor.scrollHeight.number ?? 0
        if scrollHeight > 0 { editor.style.height = .string("\(scrollHeight)px") }
    }

    private func endEdit(commit: Bool) {
        guard editing else { return }   // re-entrancy guard: hiding blurs → fires blur
        editing = false
        let value = editor.value.string ?? ""
        let handler = editCommit
        editCommit = nil
        _ = editor.setAttribute("style", "display:none")
        _ = editor.blur()
        if commit { handler?(value) }
    }

    /// `0xRRGGBB` → `#rrggbb` for the editor's text colour.
    private func cssHex(_ hex: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var s = "#"
        for shift in stride(from: 20, through: 0, by: -4) {
            s.append(digits[Int((hex >> UInt32(shift)) & 0xF)])
        }
        return s
    }
}
#endif
