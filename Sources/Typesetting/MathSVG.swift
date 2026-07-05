// MathJax tex-svg markup → per-symbol glyph paths (em units, y-up, centered).
// A hand-rolled scanner, not a general XML parser: MathJax output is
// machine-generated and regular — <defs> glyph outlines, <g> transform
// groups, <use> references, <rect> rules (fraction bars, \sqrt overlines).

import PhysicaFoundation

public enum MathSVGError: Error, Equatable, Sendable {
    case notAnSVGDocument
    /// A <use> pointed at an id that has no <defs> path. MathJax only emits
    /// this with `fontCache: "global"` — render with `fontCache: "local"`.
    case unknownReference(String)
    case noGlyphs
}

public enum MathSVG {
    /// MathJax TeX-font coordinates: 1000 units per em. dvisvgm-style output
    /// instead measures in pt at the document's design size — pass that point
    /// size as `unitsPerEm` to `glyphs`/`measuredGlyphs` (see DVISVGCompatTests,
    /// which locks that pt-scale path against a captured fixture).
    public static let mathJaxUnitsPerEm: Real = 1000

    /// MathJax reports its glyph metrics in ex; one ex is ~0.441 em in the TeX
    /// fonts, so a `vertical-align: -d ex` becomes a depth of `d · 0.441` em.
    static let emPerEx: Real = 0.441

    /// Every <use>/<rect>/inline <path> becomes one glyph (so Write/erase
    /// stagger per symbol, in document = reading order). Positions are baked
    /// into the paths — offsets stay zero — in em units, y flipped back up,
    /// the whole formula centered on its bounds.
    public static func glyphs(
        fromSVG markup: String, unitsPerEm: Real = mathJaxUnitsPerEm
    ) throws -> [PositionedGlyph] {
        var glyphPaths = try collect(fromSVG: markup, unitsPerEm: unitsPerEm).paths

        var bounds = Bounds.empty
        for path in glyphPaths {
            bounds = bounds.union(path.bounds)
        }
        let center = SIMD2<Real>(
            (bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2
        )
        glyphPaths = glyphPaths.map { $0.translated(by: -center) }

        return glyphPaths.map { PositionedGlyph(path: $0, offset: .zero) }
    }

    /// Like `glyphs(fromSVG:)` but baseline-relative instead of bounds-centered:
    /// the em coordinates keep MathJax's own baseline (y = 0), so composing
    /// per-token SVGs into a row lines them up on a shared baseline. Also returns
    /// the box depth below that baseline, parsed from the root svg's
    /// `style="vertical-align: -N.NNNex"` and converted to em (negative = below).
    public static func measuredGlyphs(
        fromSVG markup: String, unitsPerEm: Real = mathJaxUnitsPerEm
    ) throws -> (glyphs: [PositionedGlyph], baselineOffset: Real) {
        let collected = try collect(fromSVG: markup, unitsPerEm: unitsPerEm)
        let baseline = parseVerticalAlignEx(collected.rootStyle).map { $0 * emPerEx } ?? 0
        return (collected.paths.map { PositionedGlyph(path: $0, offset: .zero) }, baseline)
    }

    /// Shared scan: every glyph path in em units (y-up, baseline at 0, not
    /// centered) plus the root <svg>'s `style` attribute.
    private static func collect(
        fromSVG markup: String, unitsPerEm: Real
    ) throws -> (paths: [Path], rootStyle: String?) {
        var scanner = TagScanner(markup)
        guard let root = scanner.nextTag(), root.name == "svg" else {
            throw MathSVGError.notAnSVGDocument
        }
        let rootStyle = root.attributes["style"]

        var defs: [String: Path] = [:]
        var inDefs = false
        // (element name, accumulated transform) for every open element, so
        // closing tags pair up without tracking which ones carry transforms.
        var stack: [(name: String, transform: Affine2)] = [("svg", .identity)]
        var paths: [Path] = []

        while let tag = scanner.nextTag() {
            if tag.isClosing {
                if let top = stack.last, top.name == tag.name {
                    stack.removeLast()
                }
                if tag.name == "defs" { inDefs = false }
                continue
            }

            let parent = stack.last?.transform ?? .identity
            let local = parent * Affine2(svgTransform: tag.attributes["transform"])

            switch tag.name {
            case "defs":
                inDefs = true
            case "path":
                if inDefs, let id = tag.attributes["id"], let data = tag.attributes["d"] {
                    defs[id] = try Path.svg(data)
                } else if !inDefs, let data = tag.attributes["d"] {
                    let parsed = try Path.svg(data)
                    if !parsed.isEmpty {
                        paths.append(parsed.transformedPoints(local.apply))
                    }
                }
            case "use":
                guard !inDefs else { break }
                let href = tag.attributes["xlink:href"] ?? tag.attributes["href"] ?? ""
                let id = href.hasPrefix("#") ? String(href.dropFirst()) : href
                guard let glyph = defs[id] else { throw MathSVGError.unknownReference(id) }
                // Invisible operators (U+2061 function application etc.) are
                // defs entries with d="" — they must not occupy a glyph slot,
                // or slices like formula[(n - 4)...] land off by one.
                guard !glyph.isEmpty else { break }
                // x/y attributes are an extra translation applied after transform.
                let shifted = local * .translation(
                    SIMD2(Self.length(tag.attributes["x"]), Self.length(tag.attributes["y"]))
                )
                paths.append(glyph.transformedPoints(shifted.apply))
            case "rect":
                guard !inDefs else { break }
                let x = Self.length(tag.attributes["x"])
                let y = Self.length(tag.attributes["y"])
                let w = Self.length(tag.attributes["width"])
                let h = Self.length(tag.attributes["height"])
                guard w > 0, h > 0 else { break }
                let corners = [
                    SIMD2(x, y), SIMD2(x + w, y), SIMD2(x + w, y + h), SIMD2(x, y + h),
                ]
                paths.append(Path.polygon(points: corners).transformedPoints(local.apply))
            default:
                break
            }

            if !tag.isSelfClosing {
                stack.append((tag.name, local))
            }
        }

        guard !paths.isEmpty else { throw MathSVGError.noGlyphs }

        // Transformed coordinates are viewBox units, y-down (the root <g>'s
        // scale(1,-1) is part of the chain) → em units, y-up. MathJax's own
        // baseline (viewBox y = 0) survives as em y = 0. dvisvgm has no flip
        // group but its coordinates are already y-down page pt, so the same
        // division + negation lands in em, y-up.
        let toEm: (SIMD2<Real>) -> SIMD2<Real> = {
            SIMD2($0.x / unitsPerEm, -$0.y / unitsPerEm)
        }
        return (paths.map { $0.transformedPoints(toEm) }, rootStyle)
    }

    private static func length(_ attribute: String?) -> Real {
        attribute.flatMap { Real($0) } ?? 0
    }

    /// Pulls the signed `vertical-align: <n>ex` value out of a style string with
    /// a byte scan (no Foundation). Returns nil when absent.
    static func parseVerticalAlignEx(_ style: String?) -> Real? {
        guard let style else { return nil }
        let bytes = Array(style.utf8)
        let key = Array("vertical-align".utf8)
        guard bytes.count >= key.count else { return nil }
        var anchor = -1
        for start in 0...(bytes.count - key.count) where Array(bytes[start..<start + key.count]) == key {
            anchor = start + key.count
            break
        }
        guard anchor >= 0 else { return nil }

        var index = anchor
        func isDigit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        // Skip to the first sign or digit (past ':' and whitespace).
        while index < bytes.count {
            let b = bytes[index]
            if b == UInt8(ascii: "-") || b == UInt8(ascii: "+") || b == UInt8(ascii: ".") || isDigit(b) { break }
            index += 1
        }
        let numberStart = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") {
            index += 1
        }
        while index < bytes.count, isDigit(bytes[index]) || bytes[index] == UInt8(ascii: ".") {
            index += 1
        }
        guard index > numberStart else { return nil }
        return Real(String(decoding: bytes[numberStart..<index], as: UTF8.self))
    }
}

// `TextEntity.math(svg:)` — the entity-side face of this parser — lives in the
// kernel (Entities/TextEntityMath.swift).
