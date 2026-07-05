// TextEntity.math — formula entities from MathJax tex-svg (or dvisvgm-style)
// markup, the kernel-side face of PhysicaTypesetting's MathSVG parser.

import PhysicaMath
import PhysicaGeometry
import PhysicaTypesetting

public extension TextEntity {
    /// Formula entity from MathJax tex-svg markup (the <svg> element's outer
    /// HTML, e.g. from `MathJax.tex2svg(tex)`): `scene.play(.write(formula))`
    /// writes it symbol by symbol like any text.
    static func math(
        svg: String, fontSize: Real = 1, color: Color = .white, named name: String = "Formula",
        unitsPerEm: Real = MathSVG.mathJaxUnitsPerEm
    ) throws -> TextEntity {
        let entity = TextEntity(
            glyphs: try MathSVG.glyphs(fromSVG: svg, unitsPerEm: unitsPerEm), fontSize: fontSize
        )
        entity.components[RenderStyleComponent.self] = RenderStyleComponent(
            color: color,
            strokeColor: color,
            strokeWidth: 0.012 * fontSize,
            isFilled: true
        )
        entity.name = name
        return entity
    }
}
