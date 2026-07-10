// PlaybackBar — the native playback HUD: a play/pause/replay button, a scrub
// slider, and a time label, floating over the bottom of the MetalView. The
// native mirror of the web `PlaybackControls` (Sources/WASM/Webpage): identical
// timeline semantics — replay when the playhead is at the end, resume/pause
// otherwise, and seek-on-scrub — synced every frame from the AppRuntime tick
// loop instead of a rAF callback.

import PhysicaFoundation
import PhysicaKernel

#if os(macOS)
import AppKit

@MainActor
final class PlaybackBar: NSView {
    private let scene: Scene
    private let button = NSButton()
    private let slider = NSSlider()
    private let label = NSTextField(labelWithString: "")

    private let playImage = PlaybackBar.symbol("play.fill")
    private let pauseImage = PlaybackBar.symbol("pause.fill")
    private let replayImage = PlaybackBar.symbol("arrow.counterclockwise")

    /// True while the user drags the thumb: gates the frame-sync so the thumb
    /// tracks the pointer rather than snapping to the playhead (mirrors
    /// `PlaybackControls.isScrubbing`).
    private var isScrubbing = false
    /// Last symbol/text pushed to the controls — skip redundant per-frame writes.
    private var lastButtonKey = ""
    private var lastLabel = ""

    init(scene: Scene) {
        self.scene = scene
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.72).cgColor
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        buildControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func buildControls() {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.setButtonType(.momentaryChange)
        button.contentTintColor = .white
        button.image = playImage
        button.target = self
        button.action = #selector(togglePlayback)
        button.setContentHuggingPriority(.required, for: .horizontal)

        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = 0
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderMoved)
        // Low hugging → the slider soaks up the slack between button and label.
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .white
        label.alignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = NSStackView(views: [button, slider, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 26),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 112),
        ])
    }

    // MARK: Actions (mirror PlaybackControls' click/input listeners)

    /// Replay at the end, resume if paused, else pause.
    @objc private func togglePlayback() {
        let state = scene.timeline.state
        if Self.isAtEnd(state) {
            scene.seek(to: 0)
            scene.resume()
        } else if scene.timeline.isPaused {
            scene.resume()
        } else {
            scene.timeline.setPaused(true)
        }
    }

    /// Continuous slider drag → seek to `fraction · duration`. `isScrubbing` is
    /// cleared in `sync()` once the left button lifts (robust even if the final
    /// mouse-up action is missed).
    @objc private func sliderMoved() {
        isScrubbing = true
        scene.seek(to: slider.doubleValue * scene.timeline.duration)
    }

    /// End = playhead at the duration (a seek leaves the clip cursor ON the last
    /// clip, so `TimelineState.isFinished` can't be used — mirrors the web check).
    private static func isAtEnd(_ state: TimelineState) -> Bool {
        state.duration > 0 && state.currentTime >= state.duration - 1e-6
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
    }

    // MARK: Per-frame sync (called from AppRuntime.draw)

    /// Reflects timeline state into the controls. Called every frame after
    /// `engine.tick`, the native counterpart of `PlaybackControls.sync`.
    func sync() {
        // Belt-and-suspenders: no left button down ⇒ not scrubbing, regardless of
        // whether the slider's final mouse-up action landed.
        if isScrubbing, NSEvent.pressedMouseButtons & 0x1 == 0 { isScrubbing = false }

        let state = scene.timeline.state
        let ended = Self.isAtEnd(state)

        let key = ended ? "replay" : (state.isPaused ? "play" : "pause")
        if key != lastButtonKey {
            button.image = ended ? replayImage : (state.isPaused ? playImage : pauseImage)
            button.toolTip = ended ? "Replay" : (state.isPaused ? "Play" : "Pause")
            lastButtonKey = key
        }

        let text = "\(fmt(state.currentTime, decimals: 2)) / \(fmt(state.duration, decimals: 2)) s"
        if text != lastLabel {
            label.stringValue = text
            lastLabel = text
        }

        if !isScrubbing {
            slider.doubleValue = state.duration > 0 ? state.currentTime / state.duration : 0
        }
    }
}
#endif
