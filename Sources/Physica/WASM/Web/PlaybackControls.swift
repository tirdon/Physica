// Playback bar wiring: play/pause button, scrub slider, time label.
// All listeners attach from Swift; the HTML is inert scaffolding.

#if os(WASI)
import JavaScriptKit

@MainActor
final class PlaybackControls {
    private let scene: Scene
    private let button: JSValue
    private let slider: JSValue
    private let label: JSValue
    /// Canvas-centered overlay, shown only when the timeline has finished.
    private let replay: JSValue

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
        self.replay = document.getElementById("replay")

        listen(button, "click") { [weak self] _ in
            guard let self else { return }
            if Self.isAtEnd(self.scene.timeline.state) {
                self.restart()
            } else if self.scene.timeline.isPaused {
                self.scene.resume()
            } else {
                self.scene.timeline.setPaused(true)
            }
        }

        if !replay.isNull {
            listen(replay, "click") { [weak self] _ in
                self?.restart()
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

    /// Rewind to the start and play. Scripted clips replay deterministically;
    /// system-driven motion (pendulum, physics) re-runs live from t = 0.
    private func restart() {
        scene.seek(to: 0)
        scene.resume()
    }

    /// End = playhead at the duration. (TimelineState.isFinished tracks the
    /// clip cursor, which a seek leaves ON the last clip, not past it.)
    private static func isAtEnd(_ state: TimelineState) -> Bool {
        state.duration > 0 && state.currentTime >= state.duration - 1e-6
    }

    /// Called every frame: reflect timeline state into the DOM.
    func sync() {
        let state = scene.timeline.state
        let ended = Self.isAtEnd(state)
        button.innerText = .string(
            ended ? "Replay" : (state.isPaused ? "Play" : "Pause")
        )
        label.innerText = .string(
            "\(fmt(state.currentTime, decimals: 2)) / \(fmt(state.duration, decimals: 2)) s"
        )
        if !isScrubbing {
            let fraction = state.duration > 0 ? state.currentTime / state.duration : 0
            slider.value = .string(String(Int((fraction * 1000).rounded())))
        }
        if !replay.isNull {
            // Hidden while dragging the slider so it doesn't pop mid-scrub.
            replay.hidden = .boolean(!ended || isScrubbing)
        }
    }
}
#endif
