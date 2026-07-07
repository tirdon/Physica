// ToolbarPanel — the top tool palette (brainec-style compact icon row), built
// from Swift via JavaScriptKit into a DOM host the html shell ships empty.
//
// Phase 2: element-creation buttons. Each click appends an element to the
// current slide and recompiles. Returns the click closures so the owner can
// retain them (a dropped JSClosure detaches its listener).

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
enum ToolbarPanel {
    static func install(hostID: String, app: StudioApp) -> [JSClosure] {
        guard let document = JSObject.global.document.object else { return [] }
        var host = document.getElementById!(hostID)
        guard host.object != nil else { return [] }
        host.innerHTML = .string("")

        var closures: [JSClosure] = []

        // A labelled cluster of tools (e.g. "Geometry"); returns the row that
        // `add` appends its buttons to.
        func group(_ label: String) -> JSValue {
            var wrap = document.createElement!("div")
            wrap.className = .string("studio-group")
            var caption = document.createElement!("span")
            caption.className = .string("studio-group-label")
            caption.textContent = .string(label)
            _ = wrap.appendChild(caption)
            var row = document.createElement!("div")
            row.className = .string("studio-group-row")
            _ = wrap.appendChild(row)
            _ = host.appendChild(wrap)
            return row
        }

        func add(_ row: JSValue, _ label: String, _ action: @escaping @MainActor () -> Void) {
            var button = document.createElement!("button")
            button.textContent = .string(label)
            button.className = .string("studio-tool")
            let closure = JSClosure { _ in
                MainActor.assumeIsolated { action() }
                return .undefined
            }
            closures.append(closure)
            _ = button.addEventListener("click", closure)
            _ = row.appendChild(button)
        }

        let geometry = group("Geometry")
        add(geometry, "\u{25B2} Tri")    { app.addElement(.triangle(side: 1.6), name: "Tri", colorHex: 0xFF8FA3) }
        add(geometry, "\u{25CF} Circle") { app.addElement(.circle(radius: 1), name: "Circle", colorHex: 0x5CD0B3) }
        add(geometry, "\u{25A0} Rect")   { app.addElement(.rectangle(width: 2, height: 1.2), name: "Rect", colorHex: 0xFFD479) }

        let text = group("Text")
        add(text, "T Text")        { app.addElement(.text("Text", fontSize: 0.7), name: "Text", colorHex: 0xF2F2EC) }
        add(text, "\u{0192} Math") { app.addElement(.math(tex: "e^{i\\pi}+1=0", fontSize: 0.9), name: "Math", colorHex: 0xF2F2EC) }

        let media = group("Media")
        add(media, "\u{1F5BC} Image") {
            // A visible placeholder bitmap (5×5 red PNG); edit the Source
            // field in the inspector to point at a real URL / data: URI.
            app.addElement(
                .image(source: placeholderPNG, width: 2), name: "Image", colorHex: 0xFFFFFF)
        }

        let actions = group("Actions")
        add(actions, "\u{25B6} Play")   { app.togglePlay() }
        add(actions, "\u{21B6} Undo")   { app.undo() }
        add(actions, "\u{21B7} Redo")   { app.redo() }
        add(actions, "\u{2913} Export") { app.save() }

        return closures
    }
}

/// The 5×5 red PNG the Image tool starts with — decodes with no fetch, so a
/// fresh element is visible immediately; the inspector's Source field (or a
/// double-click on the stage) points it at a real URL / data: URI.
private let placeholderPNG = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg=="
#endif
