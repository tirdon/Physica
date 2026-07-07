// ElementBuilder — turns one `ElementDoc` into a live Physica `Entity`.
//
// The single switch over `ElementKind` is the only place document kinds map to
// concrete entity constructors, so adding a kind is a one-case change here plus
// one in `ElementKind`. Text needs a font; without one it returns `nil` and the
// compiler skips it (graceful degradation, matching the rest of the framework).
//
// Platform-neutral: every entity type used here is dependency-free core.

import Physica

@MainActor
enum ElementBuilder {
    /// Builds the live entity for `element`, or `nil` when it can't be realized
    /// (text needs a font; math needs its tex resolved to SVG in `mathSVG`).
    /// `mathSVG` maps a tex string to MathJax's SVG markup, resolved on the WASI
    /// side so this stays platform-neutral.
    static func build(_ element: ElementDoc, font: Font?, mathSVG: [String: String] = [:]) -> Entity? {
        let color = Color(hex: element.colorHex)
        let entity: Entity
        switch element.kind {
        case let .circle(radius):
            entity = Circle(radius: radius, color: color)
        case let .rectangle(width, height):
            entity = Rectangle(width: width, height: height, color: color)
        case let .triangle(side):
            entity = Triangle(side: side, color: color)
        case let .text(string, fontSize):
            guard let font else { return nil }
            // Plain text is hidden until `.write`; `.shown()` reveals it so an
            // `s.add`-ed label is visible immediately.
            entity = TextEntity(string, font: font, fontSize: fontSize, color: color).shown()
        case let .math(tex, fontSize):
            guard let svg = mathSVG[tex],
                  let math = try? TextEntity.math(svg: svg, fontSize: fontSize, color: color) else {
                return nil   // MathJax unavailable or tex unresolved → skip gracefully
            }
            entity = math.shown()
        case let .image(source, width):
            // The fill color doesn't apply to a bitmap; opacity/scale steps do.
            entity = Image(source, width: width)
        }
        entity.position = Position(element.position.x, element.position.y, 0)
        entity.name = element.name
        return entity
    }
}
