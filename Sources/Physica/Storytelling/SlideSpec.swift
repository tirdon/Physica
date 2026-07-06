// SlideSpec + the `Slide(...)` authoring element + StoryBuilder — the deferred
// slide description behind the `Storytelling { Slide { … } }` facade. A spec
// captures the slide's content closure UNEXECUTED, so the facade can finish
// its async boot (font fetches → FontBook) before any `Text(...)` inside the
// closures runs; `Story.slide(_ spec:)` then records each spec in order.
// Host-safe: nothing here touches the DOM, so specs build and unit-test on
// macOS.

import PhysicaFoundation

/// One authored slide, waiting to be recorded into a `Story`.
public struct SlideSpec {
    public var title: String
    /// Arrival effect (nil = `.none`).
    public var onAppear: SlideTransition?
    /// Exit effect for the slide's own content (nil = `.clear`).
    public var onDisappear: ExitTransition?
    /// The slide's content script — runs when the spec is recorded.
    public var body: @MainActor (Scene) -> Void

    public init(
        title: String = "",
        onAppear: SlideTransition? = nil,
        onDisappear: ExitTransition? = nil,
        body: @escaping @MainActor (Scene) -> Void
    ) {
        self.title = title
        self.onAppear = onAppear
        self.onDisappear = onDisappear
        self.body = body
    }
}

/// The authoring spelling: `Slide("name") { scene in … }`,
/// `Slide(onAppear: nil, onDisappear: .fadeOut) { … }`, or bare `Slide { … }`.
public func Slide(
    _ title: String = "",
    onAppear: SlideTransition? = nil,
    onDisappear: ExitTransition? = nil,
    _ body: @escaping @MainActor (Scene) -> Void
) -> SlideSpec {
    SlideSpec(title: title, onAppear: onAppear, onDisappear: onDisappear, body: body)
}

/// Collects `Slide(...)` expressions into the facade's slide list.
@resultBuilder
public enum StoryBuilder {
    public static func buildExpression(_ slide: SlideSpec) -> [SlideSpec] { [slide] }
    public static func buildBlock(_ parts: [SlideSpec]...) -> [SlideSpec] { parts.flatMap { $0 } }
    public static func buildOptional(_ parts: [SlideSpec]?) -> [SlideSpec] { parts ?? [] }
    public static func buildEither(first parts: [SlideSpec]) -> [SlideSpec] { parts }
    public static func buildEither(second parts: [SlideSpec]) -> [SlideSpec] { parts }
    public static func buildArray(_ parts: [[SlideSpec]]) -> [SlideSpec] { parts.flatMap { $0 } }
}

@MainActor
public extension Story {
    /// Records an authored spec: title + arrival transition + content, then the
    /// exit effect (handled inside `slide(_:transition:exit:_:)`).
    @discardableResult
    func slide(_ spec: SlideSpec) -> SlideRecord {
        slide(
            spec.title,
            transition: spec.onAppear ?? .none,
            exit: spec.onDisappear ?? .clear,
            spec.body
        )
    }
}
