// SlideListPanel — the left rail listing the story's slides (WASI only).
//
// Rebuilt from the document on every change (cheap: a handful of rows). Each row
// selects on click (seeks the player), renames inline, picks an entrance
// transition, reorders, and deletes. Returns its event closures so the owner can
// retain them across re-renders.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum SlideListPanel {
    static func render(hostID: String, app: StudioApp, document: StoryDocument, current: Int) -> [JSClosure] {
        guard let dom = JSObject.global.document.object else { return [] }
        var host = dom.getElementById!(hostID)
        guard host.object != nil else { return [] }
        host.innerHTML = .string("")

        var closures: [JSClosure] = []
        func el(_ tag: String) -> JSValue { dom.createElement!(tag) }
        func on(_ node: JSValue, _ event: String, _ handler: @escaping @MainActor () -> Void) {
            let c = JSClosure { _ in
                MainActor.assumeIsolated { handler() }
                return .undefined
            }
            closures.append(c)
            _ = node.addEventListener(event, c)
        }

        // Header: "SLIDES" + add button.
        var header = el("div")
        header.className = .string("panel-head")
        var label = el("span")
        label.textContent = .string("Slides")
        _ = header.appendChild(label)
        var addBtn = el("button")
        addBtn.className = .string("panel-add")
        addBtn.textContent = .string("+")
        on(addBtn, "click") { app.addSlide() }
        _ = header.appendChild(addBtn)
        _ = host.appendChild(header)

        for index in document.slides.indices {
            let slide = document.slides[index]
            var row = el("div")
            row.className = .string(index == current ? "slide-row selected" : "slide-row")

            var top = el("div")
            top.className = .string("slide-row-top")

            var badge = el("button")
            badge.className = .string("slide-badge")
            badge.textContent = .string("\(index + 1)")
            on(badge, "click") { app.selectSlide(index) }
            _ = top.appendChild(badge)

            var titleInput = el("input")
            titleInput.className = .string("slide-title")
            titleInput.value = .string(slide.title)
            let capturedTitle = titleInput
            on(titleInput, "change") { app.renameSlide(index, title: capturedTitle.value.string ?? "") }
            _ = top.appendChild(titleInput)

            var del = el("button")
            del.className = .string("slide-x")
            del.textContent = .string("\u{2715}")
            on(del, "click") { app.deleteSlide(index) }
            _ = top.appendChild(del)
            _ = row.appendChild(top)

            var controls = el("div")
            controls.className = .string("slide-controls")

            var sel = el("select")
            sel.className = .string("slide-transition")
            for spec in TransitionSpec.allCases {
                var opt = el("option")
                opt.value = .string(spec.rawValue)
                opt.textContent = .string(spec.label)
                if spec == slide.transition { opt.selected = .boolean(true) }
                _ = sel.appendChild(opt)
            }
            let capturedSel = sel
            on(sel, "change") {
                if let spec = TransitionSpec(rawValue: capturedSel.value.string ?? "") {
                    app.setTransition(index, spec)
                }
            }
            _ = controls.appendChild(sel)

            var up = el("button")
            up.className = .string("slide-move")
            up.textContent = .string("\u{2191}")
            on(up, "click") { app.moveSlide(index, by: -1) }
            _ = controls.appendChild(up)

            var down = el("button")
            down.className = .string("slide-move")
            down.textContent = .string("\u{2193}")
            on(down, "click") { app.moveSlide(index, by: 1) }
            _ = controls.appendChild(down)

            _ = row.appendChild(controls)
            _ = host.appendChild(row)
        }

        return closures
    }
}
#endif
