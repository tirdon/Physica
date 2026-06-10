// Playback bar wiring: play/pause button, scrub slider, time label.
// All listeners attach from Swift; the HTML is inert scaffolding.

#if os(WASI)
import JavaScriptKit
import Physica

@MainActor
final class PlaybackControls {
    private let scene: Scene
    private let button: JSValue
    private let slider: JSValue
    private let label: JSValue

    private var isScrubbing = false
    private var closures: [JSClosure] = []

    init?(scene: Scene) {
        let document = JSObject.global.document
        let button: JSValue = document.getElementById("playpause")
        let slider: JSValue = document.getElementById("scrub")
        let label: JSValue = document.getElementById("time")
        guard !button.isNull, !slider.isNull, !label.isNull else { return nil }

        self.scene = scene
        self.button = button
        self.slider = slider
        self.label = label

        listen(button, "click") { [weak self] _ in
            guard let self else { return }
            if self.scene.timeline.isPaused {
                self.scene.resume()
            } else {
                self.scene.timeline.setPaused(true)
            }
        }

        listen(slider, "input") { [weak self] _ in
            guard let self else { return }
            self.isScrubbing = true
            let raw = self.slider.value.string.flatMap(Double.init) ?? 0
            let target = TimeInterval(raw / 1000) * self.scene.timeline.duration
            self.scene.seek(to: target)
        }

        listen(slider, "change") { [weak self] _ in
            self?.isScrubbing = false
        }
    }

    private func listen(_ element: JSValue, _ event: String, _ handler: @escaping @MainActor (JSValue) -> Void) {
        let closure = JSClosure { arguments in
            let event = arguments.first ?? .undefined
            MainActor.assumeIsolated {
                handler(event)
            }
            return .undefined
        }
        closures.append(closure)
        _ = element.addEventListener(event, closure)
    }

    /// Called every frame: reflect timeline state into the DOM.
    func sync() {
        let state = scene.timeline.state
        button.innerText = .string(state.isPaused ? "Play" : "Pause")
        label.innerText = .string(
            "\(fmt(state.currentTime, decimals: 2)) / \(fmt(state.duration, decimals: 2)) s"
        )
        if !isScrubbing {
            let fraction = state.duration > 0 ? state.currentTime / state.duration : 0
            slider.value = .string(String(Int((fraction * 1000).rounded())))
        }
    }
}
#endif
