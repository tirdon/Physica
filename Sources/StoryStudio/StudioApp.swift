// StudioApp — the @MainActor owner of an editing session (WASI only).
//
// It holds the single source of truth (`StoryDocument`), the live stage
// (`StoryRuntime`), the undo/redo stack, and the compiler's `id → Entity` map.
// Every edit funnels through `mutate`, which records an undo snapshot, applies
// the change, recompiles a fresh story onto the stage (the timeline is
// append-only — editing is rebuild-then-reseek), and autosaves to localStorage.
//
// Exclusivity note: the `mutate` change closure receives the document `inout`
// and must NOT read `self.document` (e.g. via a computed property) while that
// access is live — Swift's exclusivity checker traps. Capture anything derived
// from `self` *before* calling `mutate`.
//
// Retained for the page lifetime by `StoryStudio.app` so its DOM listeners and
// the rAF loop stay live.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
final class StudioApp {
    private static let storageKey = "studio:doc:autosave"

    private var document: StoryDocument
    private let font: Font?
    private let runtime: StoryRuntime
    private var entities: [Int: Entity]
    private var history = CommandStack<StoryDocument>()
    // Ordered multi-selection. A plain click replaces it; ⌘-click toggles a
    // member. A single selection drives the inspector's property editors.
    private var selection: [Int] = []
    private var selectedStepID: Int?
    private var viewZoom: Real = 10   // editor camera extent (10 = the default fit)
    private var panelClosures: [JSClosure] = []
    private var slidePanelClosures: [JSClosure] = []
    private var inspectorClosures: [JSClosure] = []
    private var timelineClosures: [JSClosure] = []
    private var shortcutClosures: [JSClosure] = []
    private var stageOverlay: StageOverlay?
    /// Whether the hold-⌥ element-id overlay is currently shown.
    private var idOverlayShown = false

    // Active canvas-drag state. A drag moves the whole moving set together, so we
    // snapshot every member's start position keyed by id, plus their union world
    // bounds (which drive ⌥-drag alignment snapping).
    private var dragElementID: Int?
    private var dragMovingIDs: [Int] = []
    private var dragStartPositions: [Int: Vec2] = [:]
    private var dragStartWorld = Position(0, 0, 0)
    private var dragStartUnion = Bounds.empty
    private var dragMoved = false
    // ⌥-drag snaps the moving set to alignment guides. A ⌥-press defers the overlap
    // picker until pointer-up proves it was a click (no move past the slop), not a
    // drag — so ⌥-click still disambiguates overlaps while ⌥-drag aligns.
    private var snapping = false
    private var altPendingViewport: SIMD2<Real>?

    private init(document: StoryDocument, font: Font?, runtime: StoryRuntime, entities: [Int: Entity]) {
        self.document = document
        self.font = font
        self.runtime = runtime
        self.entities = entities
    }

    static func boot(font: Font?) async -> StudioApp {
        // Load MathJax once so `MathCache.svg` can resolve formulas synchronously
        // on every recompile. Failure (no DOM / CDN) just disables math.
        _ = try? await MathJaxLoader.load()

        let document = restoredDocument() ?? StoryDocument.starter()
        let build = StoryCompiler.build(document, font: font, mathSVG: resolveMathSVG(document))
        let runtime = await StoryRuntime.run(engine: build.engine, story: build.story)
        runtime.syncsDebugOverlay = false   // Shift/⌥ are editor modifiers (move-drag, id tags)
        let app = StudioApp(document: document, font: font, runtime: runtime, entities: build.entities)
        // No DOM (e.g. the GPU-free Bun smoke) → the story is built and logged
        // above; skip all editor-UI wiring, which needs the document/window.
        guard JSObject.global.document.object != nil else { return app }
        app.panelClosures = ToolbarPanel.install(hostID: "studio-toolbar", app: app)
        app.stageOverlay = StageOverlay(canvasID: "main", hostID: "scene-host", app: app)
        app.installShortcuts()
        app.refreshSlidePanel()
        app.refreshInspector()
        app.refreshTimeline()
        return app
    }

    // MARK: Keyboard shortcuts (Cmd-Z/S, Cmd-+/-/0 zoom, Delete, hold H for help)

    private func installShortcuts() {
        let window = JSObject.global.jsValue
        let keydown = JSClosure { [weak self] args in
            let event = args.first ?? .undefined
            MainActor.assumeIsolated { self?.handleShortcut(event) }
            return .undefined
        }
        let keyup = JSClosure { [weak self] args in
            let event = args.first ?? .undefined
            MainActor.assumeIsolated { self?.handleKeyUp(event) }
            return .undefined
        }
        shortcutClosures.append(keydown)
        shortcutClosures.append(keyup)
        _ = window.addEventListener("keydown", keydown)
        _ = window.addEventListener("keyup", keyup)
    }

    private func handleShortcut(_ event: JSValue) {
        let key = (event.key.string ?? "").lowercased()
        let meta = (event.metaKey.boolean ?? false) || (event.ctrlKey.boolean ?? false)
        let shift = event.shiftKey.boolean ?? false
        if key == "alt" {                   // hold ⌥ → tag every element with its id
            showIDOverlay()
            return
        }
        if meta, key == "z" {
            _ = event.preventDefault()
            if shift { redo() } else { undo() }
        } else if meta, key == "s" {
            _ = event.preventDefault()
            save()
        } else if meta, key == "=" || key == "+" {
            _ = event.preventDefault()      // override the browser's page zoom
            zoomCamera(by: 1 / 1.2)         // smaller extent = zoom in
        } else if meta, key == "-" {
            _ = event.preventDefault()
            zoomCamera(by: 1.2)             // larger extent = zoom out
        } else if meta, key == "0" {
            _ = event.preventDefault()
            resetCameraZoom()
        } else if key == "h", !meta {
            guard !isEditingText() else { return }   // don't pop help while typing an 'h'
            setHelpVisible(true)
        } else if key == "escape" {
            stageOverlay?.hideRadialPicker()   // dismiss the ⌥-click picker (no-op otherwise)
        } else if key == "delete" || key == "backspace" {
            // Don't hijack edits in a focused text field.
            guard !isEditingText() else { return }
            _ = event.preventDefault()
            deleteSelectedElement()
        }
    }

    private func handleKeyUp(_ event: JSValue) {
        let key = (event.key.string ?? "").lowercased()
        if key == "h" { setHelpVisible(false) }
        if key == "alt" { hideIDOverlay() }
    }

    // MARK: Camera zoom (editor view aid; not part of the scrubbable timeline)

    /// Scales the editor camera's visible extent (clamped). Persisted across edits
    /// by `recompile`, so a zoom survives recompiles. Instant (no timeline clip —
    /// the story player owns the playhead).
    private func zoomCamera(by factor: Real) {
        viewZoom = Swift.min(40, Swift.max(2, viewZoom * factor))
        applyViewZoom()
    }
    private func resetCameraZoom() {
        viewZoom = 10
        applyViewZoom()
    }
    private func applyViewZoom() {
        runtime.scene.frame.zoomExtent = viewZoom
        // The zoom rewrites the world→viewport mapping the selection boxes are
        // placed against, so re-place them now — otherwise they stay frozen at
        // their pre-zoom pixel rect until the next click/drag/recompile.
        updateStageOverlays()
    }

    // MARK: Element-id overlay (hold ⌥ — correlate canvas elements with the panels)

    /// Tags every element on the current slide with its id at its top-left corner.
    /// Held with ⌥; `updateStageOverlays` re-places the tags as elements drag and the
    /// camera zooms, and `hideIDOverlay` tears them down on release.
    private func showIDOverlay() {
        guard !idOverlayShown, !isEditingText() else { return }   // ⌥ also types accents in a field
        idOverlayShown = true
        placeIDLabels()
    }

    private func hideIDOverlay() {
        guard idOverlayShown else { return }
        idOverlayShown = false
        stageOverlay?.hideIDLabels()
    }

    /// Re-places the id tags over the current slide's live element bounds — a no-op
    /// unless the overlay is held up. Folded into `updateStageOverlays` so the tags
    /// follow drags / zoom / recompiles, not just the instant ⌥ is pressed.
    private func refreshIDOverlay() {
        guard idOverlayShown else { return }
        placeIDLabels()
    }

    private func placeIDLabels() {
        let slide = currentSlideIndex
        guard document.slides.indices.contains(slide) else { stageOverlay?.hideIDLabels(); return }
        let labels: [(id: Int, min: SIMD2<Real>, max: SIMD2<Real>)] =
            document.slides[slide].elements.compactMap { element in
                guard let entity = entities[element.id] else { return nil }
                let b = entity.worldBounds
                guard !b.isEmpty else { return nil }
                return (element.id, SIMD2(b.min.x, b.min.y), SIMD2(b.max.x, b.max.y))
            }
        stageOverlay?.showIDLabels(labels, scene: runtime.scene)
    }

    /// Shows/hides the held-H help sheet (a CSS-toggled modal in the shell).
    private func setHelpVisible(_ visible: Bool) {
        let sheet = JSObject.global.document.getElementById("help-sheet")
        guard sheet.object != nil else { return }
        if visible { _ = sheet.classList.add("show") } else { _ = sheet.classList.remove("show") }
    }

    private func isEditingText() -> Bool {
        let tag = (JSObject.global.document.activeElement.tagName.string ?? "").uppercased()
        return tag == "INPUT" || tag == "SELECT" || tag == "TEXTAREA"
    }

    // MARK: Canvas direct manipulation (driven by StageOverlay)

    func stagePointerDown(viewport: SIMD2<Real>, shift: Bool, meta: Bool, alt: Bool) {
        // A press anywhere commits an open inline editor (a click away = done) and
        // ends the gesture, so we never start a drag against the about-to-rebuild scene.
        if stageOverlay?.isEditing == true {
            stageOverlay?.endEditing()
            return
        }
        let world = runtime.scene.worldPosition(normalizedViewport: viewport)
        dragMoved = false
        snapping = false
        altPendingViewport = nil
        stageOverlay?.clearGuides()

        // ⌥ arms a *snapping* drag of the element under the point (or the current
        // selection, on empty space) but stays a candidate for the overlap picker:
        // if the pointer never moves past the slop, pointer-up opens the picker
        // instead — so ⌥-click still disambiguates overlaps while ⌥-drag aligns.
        if alt {
            snapping = true
            altPendingViewport = viewport
            armAltDrag(at: world)
            return
        }

        // Shift+drag moves the current selection from *anywhere* on the canvas — no
        // hit-test — so an element buried behind another (which a plain drag would
        // grab instead) can still be moved once it's selected. A bare Shift press
        // with nothing selected does nothing.
        if shift {
            beginMoveDrag(at: world)
            return
        }

        dragElementID = nil
        dragMovingIDs = []
        dragStartPositions = [:]

        guard let hit = runtime.scene.hitTest(worldXY: world),
              let id = elementID(for: hit), element(id: id) != nil else {
            // Empty space: a plain click clears; ⌘+click leaves the selection.
            if !meta { selection = []; refreshInspector(); updateStageOverlays() }
            return
        }

        if meta {
            // Toggle this element's membership; a ⌘ gesture selects, never drags.
            if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
            refreshInspector()
            updateStageOverlays()
            return
        }

        // Plain press: pressing a member of a multi-selection keeps it (so the whole
        // group drags); pressing anything else selects just that element.
        if !selection.contains(id) { selection = [id] }
        dragElementID = id
        captureDragStart(ids: selection, at: world)
        refreshInspector()
        updateStageOverlays()
    }

    /// Arms a Shift+drag: moves the current selection by the pointer delta with no
    /// hit-test, so a buried element a plain drag can't grab is still movable once
    /// selected. `dragElementID` (any selected id) is just the armed flag — the moved
    /// set is `dragStartPositions`. No-op with an empty selection.
    private func beginMoveDrag(at world: Position) {
        guard let anchor = selection.first else { return }
        dragElementID = anchor
        captureDragStart(ids: selection, at: world)
    }

    /// Arms an ⌥-drag: the moving set is the element under the point (alone) or — on
    /// empty space — the current selection (move-from-anywhere). Selection isn't
    /// changed yet; the first real move commits to it, so a no-move ⌥-click falls
    /// through to the overlap picker without a selection flash. No hit and nothing
    /// selected → nothing armed, leaving only the picker on pointer-up.
    private func armAltDrag(at world: Position) {
        dragElementID = nil
        dragMovingIDs = []
        dragStartPositions = [:]
        var ids: [Int] = []
        if let hit = runtime.scene.hitTest(worldXY: world),
           let id = elementID(for: hit), element(id: id) != nil {
            ids = [id]
        } else if !selection.isEmpty {
            ids = selection
        }
        guard let anchor = ids.first else { return }
        dragElementID = anchor
        captureDragStart(ids: ids, at: world)
    }

    /// Snapshots the moving set's start positions + union world bounds and resets
    /// the move flag. The union bounds are what ⌥-drag aligns to the guides.
    private func captureDragStart(ids: [Int], at world: Position) {
        dragMoved = false
        dragStartWorld = world
        dragMovingIDs = ids
        dragStartPositions = [:]
        var union = Bounds.empty
        for sid in ids {
            if let e = element(id: sid) { dragStartPositions[sid] = e.position }
            if let ent = entities[sid] {
                let b = ent.worldBounds
                if !b.isEmpty { union = union.union(b) }
            }
        }
        dragStartUnion = union
    }

    func stagePointerDrag(viewport: SIMD2<Real>) {
        guard dragElementID != nil else { return }
        let world = runtime.scene.worldPosition(normalizedViewport: viewport)
        var dx = world.x - dragStartWorld.x
        var dy = world.y - dragStartWorld.y

        // ⌥-drag waits for the slop before it starts moving, so a tiny jitter during
        // a ⌥-click still falls through to the overlap picker on pointer-up.
        let metrics = snapMetrics()
        if snapping, !dragMoved, (dx * dx + dy * dy) < metrics.slop * metrics.slop { return }
        if Swift.abs(dx) > 1e-4 || Swift.abs(dy) > 1e-4 { dragMoved = true }

        if snapping {
            // First committed move selects the moving set (so its box shows) and
            // snaps the union bounds to the nearest alignment, drawing the guides.
            if selection != dragMovingIDs { selection = dragMovingIDs; refreshInspector() }
            let snap = computeSnap(rawDx: dx, rawDy: dy, metrics: metrics)
            dx += snap.dx; dy += snap.dy
            stageOverlay?.showGuides(snap.guides, scene: runtime.scene)
        }

        // Live-update the entities directly for a smooth drag (no recompile); the
        // document is committed once, as one undo entry, on pointer-up.
        for (sid, start) in dragStartPositions {
            entities[sid]?.position = Position(start.x + dx, start.y + dy, 0)
        }
        updateStageOverlays()
    }

    func stagePointerUp(viewport: SIMD2<Real>) {
        let wasAlt = snapping
        let pickerViewport = altPendingViewport
        let armed = dragElementID
        dragElementID = nil
        snapping = false
        altPendingViewport = nil
        stageOverlay?.clearGuides()

        guard dragMoved else {
            // A press with no movement: a ⌥-press falls through to the overlap picker
            // (⌥-click); a plain press was just a selection (already applied).
            if wasAlt, let pickerViewport { presentOverlapPicker(viewport: pickerViewport) }
            return
        }
        guard armed != nil else { return }

        let world = runtime.scene.worldPosition(normalizedViewport: viewport)
        var dx = world.x - dragStartWorld.x
        var dy = world.y - dragStartWorld.y
        if wasAlt {
            let snap = computeSnap(rawDx: dx, rawDy: dy, metrics: snapMetrics())
            dx += snap.dx; dy += snap.dy
        }
        let starts = dragStartPositions   // capture before the inout mutate
        // One coalescing label per moving set → a repeated nudge stays one undo.
        let label = "drag-" + starts.keys.sorted().map(String.init).joined(separator: ",")
        mutate(label) { doc in
            for s in doc.slides.indices {
                for e in doc.slides[s].elements.indices {
                    if let start = starts[doc.slides[s].elements[e].id] {
                        doc.slides[s].elements[e].position = Vec2(start.x + dx, start.y + dy)
                    }
                }
            }
        }
        updateStageOverlays()
    }

    /// World-space snap threshold + click/drag slop, from a fixed pixel feel (8 px /
    /// 4 px) and the editor camera's live world-per-pixel, so the snap stays a
    /// constant on-screen distance at any zoom.
    private struct SnapMetrics { var threshold: Real; var slop: Real }
    private func snapMetrics() -> SnapMetrics {
        let px = stageOverlay?.canvasPixelSize ?? SIMD2(1, 1)
        let worldPerPx = px.x > 0 ? runtime.scene.size.x / px.x : 0
        return SnapMetrics(threshold: 8 * worldPerPx, slop: 4 * worldPerPx)
    }

    /// Resolves the alignment snap for the current drag: the moving set's union
    /// bounds at the raw delta vs. the screen centre and every *other* on-slide
    /// element. An empty union (nothing measurable) yields no snap.
    private func computeSnap(rawDx: Real, rawDy: Real, metrics: SnapMetrics) -> SnapOutcome {
        guard !dragStartUnion.isEmpty else { return .none }
        let moving = SnapBox(bounds: dragStartUnion).shifted(dx: rawDx, dy: rawDy)
        let movingSet = Set(dragMovingIDs)
        let slide = currentSlideIndex
        var others: [SnapBox] = []
        if document.slides.indices.contains(slide) {
            for el in document.slides[slide].elements where !movingSet.contains(el.id) {
                if let ent = entities[el.id] {
                    let b = ent.worldBounds
                    if !b.isEmpty { others.append(SnapBox(bounds: b)) }
                }
            }
        }
        let center = runtime.scene.worldPosition(normalizedViewport: SIMD2(0.5, 0.5))
        let frame = SnapBox(bounds: runtime.scene.frameBounds)
        return AlignmentSnap.resolve(
            moving: moving, others: others,
            screenCenter: (center.x, center.y),
            frame: frame, threshold: metrics.threshold
        )
    }

    /// ⌥-click handler: gather every element under the point (deduped by id, topmost
    /// first) and raise the radial picker so the user can reach a buried one. One hit
    /// has nothing to disambiguate → select it directly; none → clear, like a plain
    /// click on empty space. A chip click routes back through `selectElement`.
    private func presentOverlapPicker(viewport: SIMD2<Real>) {
        let world = runtime.scene.worldPosition(normalizedViewport: viewport)
        var ids: [Int] = []
        var seen = Set<Int>()
        for hit in runtime.scene.hitTestAll(worldXY: world).reversed() {   // topmost first
            guard let id = elementID(for: hit), element(id: id) != nil else { continue }
            if seen.insert(id).inserted { ids.append(id) }
        }
        guard ids.count > 1 else {
            if let only = ids.first { selectElement(only) }
            else { selection = []; refreshInspector(); updateStageOverlays() }
            return
        }
        let items: [(id: Int, colorHex: UInt32)] = ids.map { id in
            (id, element(id: id)?.colorHex ?? 0x53F0FF)
        }
        stageOverlay?.showRadialPicker(centerViewport: viewport, items: items)
    }

    /// Double-click a text or math element to edit it inline on the canvas (a
    /// textarea overlaid on its bounds); shapes just select; **empty space drops a
    /// new text element there** and opens it for editing. Commit (Enter / click-away)
    /// recompiles with the new text; Escape and a no-op edit change nothing.
    func stageDoubleClick(viewport: SIMD2<Real>) {
        let world = runtime.scene.worldPosition(normalizedViewport: viewport)
        guard let hit = runtime.scene.hitTest(worldXY: world),
              let id = elementID(for: hit), element(id: id) != nil else {
            addTextAndEdit(at: world)   // empty space → create a text element here
            return
        }
        selection = [id]
        refreshInspector()
        updateStageOverlays()
        beginInlineEdit(id: id)   // text/math → editor; shapes → no editableText → just selected
    }

    /// Opens the inline editor for an element (no-op for shapes / unbuilt entities).
    private func beginInlineEdit(id: Int) {
        guard let element = element(id: id),
              let original = element.kind.editableText,
              let entity = entities[id] else { return }
        let bounds = entity.worldBounds
        guard !bounds.isEmpty else { return }
        stageOverlay?.beginEditing(
            text: original,
            worldMin: SIMD2(bounds.min.x, bounds.min.y),
            worldMax: SIMD2(bounds.max.x, bounds.max.y),
            colorHex: element.colorHex,
            scene: runtime.scene
        ) { [weak self] newValue in
            guard newValue != original else { return }   // unchanged → no undo entry
            self?.updateElement(id, label: "edit-\(id)") { $0.kind = $0.kind.withEditableText(newValue) }
        }
    }

    /// Drops a new text element at a world position and immediately opens its editor.
    /// Needs a font (text can't be realized without one); silently no-ops otherwise.
    private func addTextAndEdit(at world: Position) {
        guard font != nil, !document.slides.isEmpty else { return }
        let slide = currentSlideIndex          // read self.document BEFORE the inout access
        let pos = Vec2(world.x, world.y)
        let newID = document.nextElementID
        selection = [newID]
        mutate { doc in
            let index = Swift.max(0, Swift.min(slide, doc.slides.count - 1))
            let id = doc.nextElementID
            doc.nextElementID += 1
            doc.slides[index].elements.append(
                ElementDoc(id: id, name: "Text \(id)", kind: .text("Text", fontSize: 0.7),
                           position: pos, colorHex: 0xF2F2EC)
            )
        }
        beginInlineEdit(id: newID)   // entity exists after the recompile
    }

    /// Looks up the element doc behind a hit entity (walking up parents), then
    /// draws the selection box over the live entity's world bounds.
    private func elementID(for entity: Entity) -> Int? {
        var node: Entity? = entity
        while let current = node {
            if let match = entities.first(where: { $0.value === current })?.key { return match }
            node = current.parent
        }
        return nil
    }

    private func element(id: Int) -> ElementDoc? {
        for slide in document.slides {
            if let found = slide.elements.first(where: { $0.id == id }) { return found }
        }
        return nil
    }

    /// Re-places every stage overlay over its element's live world bounds: the
    /// selection boxes, plus the hold-⌥ id tags when shown. Called wherever bounds
    /// move — selection, drag, zoom, recompile — so the overlays track the canvas.
    private func updateStageOverlays() {
        let rects: [(min: SIMD2<Real>, max: SIMD2<Real>)] = selection.compactMap { id in
            guard let entity = entities[id] else { return nil }
            let b = entity.worldBounds
            guard !b.isEmpty else { return nil }
            return (SIMD2(b.min.x, b.min.y), SIMD2(b.max.x, b.max.y))
        }
        stageOverlay?.showSelections(rects, scene: runtime.scene)
        refreshIDOverlay()
    }

    // MARK: Edit pipeline

    /// The single mutation funnel: snapshot for undo, apply, recompile, autosave.
    /// The `change` closure must not touch `self.document` (the inout holds it).
    private func mutate(_ label: String? = nil, _ change: (inout StoryDocument) -> Void) {
        history.record(document, coalescingLabel: label)
        change(&document)
        recompile()
        autosave()
    }

    /// Rebuilds the story from the current document and swaps it onto the stage,
    /// preserving the slide the user was viewing (reload resets the player to
    /// slide 0, so we seek back) and refreshing the slide rail.
    private func recompile() {
        let keepSlide = runtime.player.currentSlideIndex
        let build = StoryCompiler.build(document, font: font, mathSVG: Self.resolveMathSVG(document))
        entities = build.entities
        runtime.reload(engine: build.engine, story: build.story)
        runtime.player.seek(toSlide: Swift.max(0, Swift.min(keepSlide, document.slides.count - 1)))
        applyViewZoom()   // a fresh scene resets the camera; restore the editor's zoom
        refreshSlidePanel()
        refreshInspector()
        refreshTimeline()
        updateStageOverlays()
    }

    private func refreshSlidePanel() {
        slidePanelClosures = SlideListPanel.render(
            hostID: "studio-slides", app: self,
            document: document, current: runtime.player.currentSlideIndex
        )
    }

    private func refreshInspector() {
        inspectorClosures = InspectorPanel.render(
            hostID: "studio-inspector", app: self,
            document: document, slide: runtime.player.currentSlideIndex, selected: selection
        )
    }

    private func refreshTimeline() {
        timelineClosures = TimelinePanel.render(
            hostID: "studio-timeline", app: self,
            document: document, slide: runtime.player.currentSlideIndex, selectedStep: selectedStepID
        )
    }

    /// The slide the user is currently viewing — where new elements land.
    private var currentSlideIndex: Int {
        Swift.max(0, Swift.min(runtime.player.currentSlideIndex, document.slides.count - 1))
    }

    // MARK: Commands (wired to the toolbar)

    /// Appends a new element to the current slide and selects it.
    func addElement(_ kind: ElementKind, name: String, colorHex: UInt32) {
        guard !document.slides.isEmpty else { return }
        let slide = currentSlideIndex     // read self.document BEFORE the inout access
        let newID = document.nextElementID
        selection = [newID]               // so the recompile's inspector shows it
        mutate { doc in
            let index = Swift.max(0, Swift.min(slide, doc.slides.count - 1))
            let id = doc.nextElementID
            doc.nextElementID += 1
            let n = doc.slides[index].elements.count
            // Cascade successive adds so they don't perfectly overlap.
            let position = Vec2(Real(n % 4) * 0.7 - 1.0, 1.6 - Real(n % 4) * 0.7)
            doc.slides[index].elements.append(
                ElementDoc(id: id, name: "\(name) \(id)", kind: kind, position: position, colorHex: colorHex)
            )
        }
    }

    // MARK: Element selection + editing

    /// Selects a single element for inspection/editing (no document change).
    func selectElement(_ id: Int) {
        selection = [id]
        refreshInspector()
        updateStageOverlays()
    }

    /// Adds/removes an element from the selection (⌘+click in the inspector list).
    func toggleSelection(_ id: Int) {
        if let i = selection.firstIndex(of: id) { selection.remove(at: i) } else { selection.append(id) }
        refreshInspector()
        updateStageOverlays()
    }

    /// Finds an element by id across slides and applies `change`, then recompiles.
    func updateElement(_ id: Int, label: String? = nil, _ change: @escaping (inout ElementDoc) -> Void) {
        mutate(label) { doc in
            for s in doc.slides.indices {
                if let e = doc.slides[s].elements.firstIndex(where: { $0.id == id }) {
                    change(&doc.slides[s].elements[e])
                    return
                }
            }
        }
    }

    func undo() {
        guard let restored = history.undo(current: document) else { return }
        document = restored
        recompile()
        autosave()
    }

    func redo() {
        guard let restored = history.redo(current: document) else { return }
        document = restored
        recompile()
        autosave()
    }

    // MARK: Slide commands

    func addSlide() {
        let target = document.slides.count
        mutate { doc in
            doc.slides.append(SlideDoc(title: "Slide \(doc.slides.count + 1)"))
        }
        selectSlide(target)
    }

    func deleteSlide(_ index: Int) {
        guard document.slides.count > 1 else { return }   // keep at least one slide
        mutate { doc in
            guard doc.slides.indices.contains(index) else { return }
            doc.slides.remove(at: index)
        }
    }

    func renameSlide(_ index: Int, title: String) {
        mutate("rename-\(index)") { doc in
            guard doc.slides.indices.contains(index) else { return }
            doc.slides[index].title = title
        }
    }

    func setTransition(_ index: Int, _ spec: TransitionSpec) {
        mutate("transition-\(index)") { doc in
            guard doc.slides.indices.contains(index) else { return }
            doc.slides[index].transition = spec
        }
    }

    func moveSlide(_ index: Int, by delta: Int) {
        let target = index + delta
        guard document.slides.indices.contains(index),
              document.slides.indices.contains(target) else { return }
        mutate { doc in doc.slides.swapAt(index, target) }
        selectSlide(target)
    }

    // MARK: Step (animation) commands

    func selectStep(_ id: Int) {
        selectedStepID = id
        refreshTimeline()
    }

    /// Appends a new step animating `elementID`, chained after the slide's last step.
    func addStep(_ elementID: Int) {
        let slide = currentSlideIndex
        let newID = document.nextStepID
        selectedStepID = newID
        mutate { doc in
            guard doc.slides.indices.contains(slide) else { return }
            let id = doc.nextStepID
            doc.nextStepID += 1
            let start = doc.slides[slide].steps.map { $0.start + $0.duration }.max() ?? 0
            doc.slides[slide].steps.append(
                StepDoc(id: id, elementID: elementID, verb: .fade(to: 0), start: start, duration: 1)
            )
        }
    }

    func setStepVerb(_ id: Int, _ verb: VerbSpec) {
        updateStep(id, label: "verb-\(id)") { $0.verb = verb }
    }

    func setStepTiming(_ id: Int, start: Double?, duration: Double?) {
        updateStep(id, label: "time-\(id)") { step in
            if let start { step.start = Swift.max(0, start) }
            if let duration { step.duration = Swift.max(0.05, duration) }
        }
    }

    func deleteStep(_ id: Int) {
        selectedStepID = nil
        mutate { doc in
            for s in doc.slides.indices {
                if let i = doc.slides[s].steps.firstIndex(where: { $0.id == id }) {
                    doc.slides[s].steps.remove(at: i)
                    return
                }
            }
        }
    }

    private func updateStep(_ id: Int, label: String? = nil, _ change: @escaping (inout StepDoc) -> Void) {
        mutate(label) { doc in
            for s in doc.slides.indices {
                if let i = doc.slides[s].steps.firstIndex(where: { $0.id == id }) {
                    change(&doc.slides[s].steps[i])
                    return
                }
            }
        }
    }

    /// Navigates to a slide (no document change — not undoable).
    func selectSlide(_ index: Int) {
        let clamped = Swift.max(0, Swift.min(index, document.slides.count - 1))
        runtime.player.seek(toSlide: clamped)
        selection = []   // selection doesn't carry across slides
        selectedStepID = nil
        dragElementID = nil
        stageOverlay?.hideSelection()
        stageOverlay?.hideRadialPicker()   // a stray picker shouldn't survive a slide change
        refreshSlidePanel()
        refreshInspector()
        refreshTimeline()
    }

    /// Exports the current document as a downloadable JSON file.
    func save() {
        guard let json = try? StoryDocumentIO.encode(document) else { return }
        FileIO.download(filename: "story.json", json: json)
    }

    /// Plays / pauses scripted playback (autoplay walks beat to beat).
    func togglePlay() {
        runtime.player.toggleAutoplay()
    }

    /// Deletes every selected element (and any steps targeting them) in one undo.
    func deleteSelectedElement() {
        let ids = Set(selection)
        guard !ids.isEmpty else { return }
        selection = []
        stageOverlay?.hideSelection()
        mutate { doc in
            for s in doc.slides.indices {
                doc.slides[s].elements.removeAll { ids.contains($0.id) }
                doc.slides[s].steps.removeAll { ids.contains($0.elementID) }
            }
        }
    }

    // MARK: Persistence

    private func autosave() {
        guard let json = try? StoryDocumentIO.encode(document) else { return }
        FileIO.saveLocal(key: Self.storageKey, json: json)
    }

    private static func restoredDocument() -> StoryDocument? {
        guard let json = FileIO.loadLocal(key: storageKey) else { return nil }
        return try? StoryDocumentIO.decode(json)
    }

    /// Resolves every distinct math tex in the document to MathJax SVG (memoized),
    /// off the hot rebuild path, for the compiler to build glyphs from.
    private static func resolveMathSVG(_ document: StoryDocument) -> [String: String] {
        var map: [String: String] = [:]
        for slide in document.slides {
            for element in slide.elements {
                if case let .math(tex, _) = element.kind, map[tex] == nil {
                    if let svg = MathCache.svg(for: tex) { map[tex] = svg }
                }
            }
        }
        return map
    }
}
#endif
