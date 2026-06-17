// TimelinePanel — the bottom rail: per-element tracks of animation steps, plus a
// step editor for the selected step (WASI only).
//
// Each element gets a lane; its steps render as blocks positioned by start/
// duration. Clicking a block selects it; "+" adds a step. The editor below tunes
// the selected step's verb, value, start, and duration. Rebuilt on every change.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum TimelinePanel {
    static let pps: Double = 90   // pixels per timeline second

    static func render(hostID: String, app: StudioApp, document: StoryDocument, slide: Int, selectedStep: Int?) -> [JSClosure] {
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
        func add(_ n: JSValue, to p: JSValue) { _ = p.appendChild(n) }
        func numInput(_ value: Real, step: String = "0.1", _ apply: @escaping @MainActor (Real) -> Void) -> JSValue {
            var input = el("input")
            input.type = .string("number")
            _ = input.setAttribute("step", step)
            input.value = .string(shortNum(value))
            let captured = input
            on(input, "change") { if let v = Double(captured.value.string ?? "") { apply(Real(v)) } }
            return input
        }
        func propRow(_ parent: JSValue, _ label: String, _ control: JSValue) {
            var row = el("label"); row.className = .string("prop")
            var span = el("span"); span.textContent = .string(label)
            add(span, to: row); add(control, to: row); add(row, to: parent)
        }

        var header = el("div"); header.className = .string("panel-head")
        var htitle = el("span"); htitle.textContent = .string("Timeline"); add(htitle, to: header)
        add(header, to: host)

        guard document.slides.indices.contains(slide) else { return closures }
        let elements = document.slides[slide].elements
        let steps = document.slides[slide].steps

        if elements.isEmpty {
            var empty = el("div"); empty.className = .string("panel-empty")
            empty.textContent = .string("Add elements, then animate them here.")
            add(empty, to: host)
            return closures
        }

        var tracks = el("div"); tracks.className = .string("tl-tracks")
        for element in elements {
            var row = el("div"); row.className = .string("tl-row")
            var label = el("div"); label.className = .string("tl-label"); label.textContent = .string(element.name)
            add(label, to: row)

            var lane = el("div"); lane.className = .string("tl-lane")
            for step in steps where step.elementID == element.id {
                var block = el("div")
                block.className = .string(step.id == selectedStep ? "tl-step selected" : "tl-step")
                _ = block.setAttribute("style", "left:\(step.start * pps)px;width:\(Swift.max(step.duration * pps, 18))px")
                block.textContent = .string(step.verb.label)
                let sid = step.id
                on(block, "click") { app.selectStep(sid) }
                add(block, to: lane)
            }
            add(lane, to: row)

            var plus = el("button"); plus.className = .string("tl-add"); plus.textContent = .string("+")
            let eid = element.id
            on(plus, "click") { app.addStep(eid) }
            add(plus, to: row)
            add(row, to: tracks)
        }
        add(tracks, to: host)

        guard let selectedStep, let step = steps.first(where: { $0.id == selectedStep }) else { return closures }
        let sid = step.id

        var editor = el("div"); editor.className = .string("tl-editor")

        var verbSel = el("select"); verbSel.className = .string("slide-transition")
        for kind in VerbKind.allCases {
            var opt = el("option"); opt.value = .string(kind.rawValue); opt.textContent = .string(kind.label)
            if kind == step.verb.kind { opt.selected = .boolean(true) }
            add(opt, to: verbSel)
        }
        let capturedVerb = verbSel
        on(verbSel, "change") {
            if let kind = VerbKind(rawValue: capturedVerb.value.string ?? "") {
                app.setStepVerb(sid, VerbSpec.makeDefault(kind))
            }
        }
        propRow(editor, "Verb", verbSel)

        switch step.verb {
        case let .fade(to):
            propRow(editor, "To", numInput(to) { v in app.setStepVerb(sid, .fade(to: v)) })
        case let .scaleTo(factor):
            propRow(editor, "Factor", numInput(factor) { v in app.setStepVerb(sid, .scaleTo(v)) })
        case let .color(hex):
            var color = el("input"); color.type = .string("color"); color.value = .string(hexString(hex))
            let cap = color
            on(color, "change") { app.setStepVerb(sid, .color(hex: parseHex(cap.value.string ?? "#ffffff"))) }
            propRow(editor, "Color", color)
        case .write, .wait:
            break
        }

        propRow(editor, "Start", numInput(Real(step.start)) { v in app.setStepTiming(sid, start: Double(v), duration: nil) })
        propRow(editor, "Dur", numInput(Real(step.duration)) { v in app.setStepTiming(sid, start: nil, duration: Double(v)) })

        var del = el("button"); del.className = .string("tl-del"); del.textContent = .string("Delete step")
        on(del, "click") { app.deleteStep(sid) }
        add(del, to: editor)

        add(editor, to: host)
        return closures
    }

    private static func shortNum(_ value: Real) -> String {
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
