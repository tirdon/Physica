// InspectorPanel — the right rail: the current slide's element list plus
// property editors for the selected element (WASI only).
//
// Selecting an element here is the same selection Phase 6's canvas click drives.
// Each property edit funnels through `app.updateElement`, which finds the element
// by id and recompiles. Rebuilt on every change; returns its closures to retain.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum InspectorPanel {
    static func render(hostID: String, app: StudioApp, document: StoryDocument, slide: Int, selected: [Int]) -> [JSClosure] {
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
        func onEvent(_ node: JSValue, _ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
            let c = JSClosure { args in
                let e = args.first ?? .undefined
                MainActor.assumeIsolated { handler(e) }
                return .undefined
            }
            closures.append(c)
            _ = node.addEventListener(event, c)
        }
        func add(_ node: JSValue, to parent: JSValue) { _ = parent.appendChild(node) }

        func subhead(_ text: String) {
            var s = el("div")
            s.className = .string("inspector-sub")
            s.textContent = .string(text)
            add(s, to: host)
        }
        func numberField(_ label: String, _ value: Real, _ apply: @escaping @MainActor (Real) -> Void) {
            var field = el("label"); field.className = .string("prop")
            var span = el("span"); span.textContent = .string(label); add(span, to: field)
            var input = el("input"); input.type = .string("number")
            _ = input.setAttribute("step", "0.1")
            input.value = .string(fmt(value))
            let captured = input
            on(input, "change") { if let v = Double(captured.value.string ?? "") { apply(Real(v)) } }
            add(input, to: field)
            add(field, to: host)
        }
        func textField(_ label: String, _ value: String, _ apply: @escaping @MainActor (String) -> Void) {
            var field = el("label"); field.className = .string("prop")
            var span = el("span"); span.textContent = .string(label); add(span, to: field)
            var input = el("input"); input.type = .string("text"); input.value = .string(value)
            let captured = input
            on(input, "change") { apply(captured.value.string ?? "") }
            add(input, to: field)
            add(field, to: host)
        }
        // Text/math size as heading levels (H1 largest → H6 smallest) instead of a raw
        // number. The element still stores a `fontSize: Real`; the dropdown shows the
        // level nearest the stored size and writes the chosen level's preset value, so
        // existing documents (any size) keep loading.
        func headingField(_ label: String, _ value: Real, _ apply: @escaping @MainActor (Real) -> Void) {
            var field = el("label"); field.className = .string("prop")
            var span = el("span"); span.textContent = .string(label); add(span, to: field)
            var select = el("select")
            var current = 0
            var bestDiff = Double.greatestFiniteMagnitude
            for (i, preset) in headingSizes.enumerated() {
                var opt = el("option")
                opt.value = .string(String(i))
                opt.textContent = .string(preset.label)
                add(opt, to: select)
                let diff = Swift.abs(Double(value) - Double(preset.size))
                if diff < bestDiff { bestDiff = diff; current = i }
            }
            select.value = .string(String(current))
            let captured = select
            on(select, "change") {
                if let i = Int(captured.value.string ?? ""), headingSizes.indices.contains(i) {
                    apply(headingSizes[i].size)
                }
            }
            add(select, to: field)
            add(field, to: host)
        }

        var header = el("div"); header.className = .string("panel-head")
        var htitle = el("span"); htitle.textContent = .string("Inspector"); add(htitle, to: header)
        add(header, to: host)

        guard document.slides.indices.contains(slide) else { return closures }
        let elements = document.slides[slide].elements

        subhead("Elements")
        if elements.isEmpty {
            var empty = el("div"); empty.className = .string("panel-empty")
            empty.textContent = .string("No elements on this slide.")
            add(empty, to: host)
        }
        for element in elements {
            var row = el("button")
            row.className = .string(selected.contains(element.id) ? "elem-row selected" : "elem-row")
            row.textContent = .string(element.name)
            let id = element.id
            // ⌘/Ctrl+click toggles membership (multi-select); a plain click replaces.
            onEvent(row, "click") { e in
                let meta = (e.metaKey.boolean ?? false) || (e.ctrlKey.boolean ?? false)
                if meta { app.toggleSelection(id) } else { app.selectElement(id) }
            }
            add(row, to: host)
        }

        // Property editors target a single element; for a multi-selection show a
        // count instead (positions still edit together by dragging on the canvas).
        if selected.count > 1 {
            subhead("Properties")
            var note = el("div"); note.className = .string("panel-empty")
            note.textContent = .string("\(selected.count) elements selected")
            add(note, to: host)
            return closures
        }
        guard let only = selected.first, let element = elements.first(where: { $0.id == only }) else { return closures }
        let id = element.id

        subhead("Properties")
        textField("Name", element.name) { name in
            app.updateElement(id, label: "name-\(id)") { $0.name = name }
        }
        numberField("X", element.position.x) { v in
            app.updateElement(id, label: "x-\(id)") { $0.position.x = v }
        }
        numberField("Y", element.position.y) { v in
            app.updateElement(id, label: "y-\(id)") { $0.position.y = v }
        }

        var colorField = el("label"); colorField.className = .string("prop")
        var cspan = el("span"); cspan.textContent = .string("Color"); add(cspan, to: colorField)
        var colorInput = el("input"); colorInput.type = .string("color")
        colorInput.value = .string(hexString(element.colorHex))
        let capturedColor = colorInput
        on(colorInput, "change") {
            let hex = parseHex(capturedColor.value.string ?? "#ffffff")
            app.updateElement(id, label: "color-\(id)") { $0.colorHex = hex }
        }
        add(colorInput, to: colorField)
        add(colorField, to: host)

        switch element.kind {
        case let .text(string, fontSize):
            textField("Text", string) { newText in
                app.updateElement(id, label: "txt-\(id)") { $0.kind = $0.kind.withEditableText(newText) }
            }
            headingField("Text size", fontSize) { v in
                app.updateElement(id, label: "fs-\(id)") { e in
                    if case let .text(s, _) = e.kind { e.kind = .text(s, fontSize: v) }
                }
            }
        case let .math(tex, fontSize):
            textField("TeX", tex) { newTex in
                app.updateElement(id, label: "tex-\(id)") { $0.kind = $0.kind.withEditableText(newTex) }
            }
            headingField("Text size", fontSize) { v in
                app.updateElement(id, label: "mfs-\(id)") { e in
                    if case let .math(t, _) = e.kind { e.kind = .math(tex: t, fontSize: v) }
                }
            }
        case let .circle(radius):
            numberField("Radius", radius) { v in
                app.updateElement(id, label: "r-\(id)") { $0.kind = .circle(radius: v) }
            }
        case let .rectangle(width, height):
            numberField("Width", width) { v in
                app.updateElement(id, label: "w-\(id)") { e in
                    if case let .rectangle(_, h) = e.kind { e.kind = .rectangle(width: v, height: h) }
                }
            }
            numberField("Height", height) { v in
                app.updateElement(id, label: "h-\(id)") { e in
                    if case let .rectangle(w, _) = e.kind { e.kind = .rectangle(width: w, height: v) }
                }
            }
        case let .triangle(side):
            numberField("Side", side) { v in
                app.updateElement(id, label: "s-\(id)") { $0.kind = .triangle(side: v) }
            }
        }

        return closures
    }

    // MARK: Formatting helpers

    /// Heading-level size presets (H1 largest → H6 smallest) in the framework's
    /// font-size units. The default body Text (0.7) lands on H5 and the "Story
    /// Studio" title (0.9) on H4, so existing content reads as a sensible level.
    static let headingSizes: [(label: String, size: Real)] = [
        ("H1", 1.6), ("H2", 1.3), ("H3", 1.05), ("H4", 0.85), ("H5", 0.7), ("H6", 0.55),
    ]

    private static func fmt(_ value: Real) -> String {
        let rounded = (Double(value) * 1000).rounded() / 1000
        return String(rounded)
    }

    private static func hexString(_ hex: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var s = "#"
        for shift in stride(from: 20, through: 0, by: -4) {
            s.append(digits[Int((hex >> UInt32(shift)) & 0xF)])
        }
        return s
    }

    private static func parseHex(_ s: String) -> UInt32 {
        let body = s.hasPrefix("#") ? String(s.dropFirst()) : s
        return UInt32(body, radix: 16) ?? 0xFFFFFF
    }
}
#endif
