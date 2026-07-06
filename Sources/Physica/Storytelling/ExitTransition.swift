// ExitTransition — how a slide's own content leaves when the viewer advances
// past it (`Slide(onDisappear: .fadeOut) { … }`). The counterpart of
// `SlideTransition` (the *arrival* effect): a non-`.clear` exit enqueues a
// short animation on the slide's introduced set as its final beat, and the
// existing deferred auto-clear then drops the (now invisible) entities at the
// next slide's boundary. Scrub-safe for free — the exit is ordinary fade/scale
// tracks and the clear is the ordinary `SlideClearTrack`.

import PhysicaFoundation

public struct ExitTransition: Sendable {
    enum Kind: Sendable {
        case clear
        case fadeOut
        case zoomOut
    }

    let kind: Kind
    let duration: Duration

    /// No exit animation — content simply clears at the boundary (the default).
    public static var clear: ExitTransition {
        ExitTransition(kind: .clear, duration: .zero)
    }

    /// The slide's content fades to transparent as its final beat.
    public static var fadeOut: ExitTransition { fadeOut() }

    public static func fadeOut(duration: Duration = .seconds(0.6)) -> ExitTransition {
        ExitTransition(kind: .fadeOut, duration: duration)
    }

    /// The content shrinks away while fading — a receding "zoom out".
    public static var zoomOut: ExitTransition { zoomOut() }

    public static func zoomOut(duration: Duration = .seconds(0.6)) -> ExitTransition {
        ExitTransition(kind: .zoomOut, duration: duration)
    }

    /// The per-entity animations of this exit, or nil when there is nothing to
    /// play (`.clear`). Called by `Story.slide` with the slide's introduced set.
    @MainActor
    func animations(for entities: [Entity]) -> [any Animatable]? {
        switch kind {
        case .clear:
            return nil
        case .fadeOut:
            return entities.map { $0.fade(to: 0) }
        case .zoomOut:
            return entities.map { $0.fade(to: 0).scale(to: 0.05) }
        }
    }
}
