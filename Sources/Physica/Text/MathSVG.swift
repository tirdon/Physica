// MathJax tex-svg markup → per-symbol glyph paths (em units, y-up, centered).
// A hand-rolled scanner, not a general XML parser: MathJax output is
// machine-generated and regular — <defs> glyph outlines, <g> transform
// groups, <use> references, <rect> rules (fraction bars, \sqrt overlines).

public enum MathSVGError: Error, Equatable, Sendable {
    case notAnSVGDocument
    /// A <use> pointed at an id that has no <defs> path. MathJax only emits
    /// this with `fontCache: "global"` — render with `fontCache: "local"`.
    case unknownReference(String)
    case noGlyphs
}

public enum MathSVG {
    /// MathJax TeX-font coordinates: 1000 units per em.
    static let unitsPerEm: Real = 1000

    /// Every <use>/<rect>/inline <path> becomes one glyph (so Write/erase
    /// stagger per symbol, in document = reading order). Positions are baked
    /// into the paths — offsets stay zero — in em units, y flipped back up,
    /// the whole formula centered on its bounds.
    public static func glyphs(fromSVG markup: String) throws -> [TextComponent.PositionedGlyph] {
        var scanner = TagScanner(markup)
        guard let root = scanner.nextTag(), root.name == "svg" else {
            throw MathSVGError.notAnSVGDocument
        }

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
        // scale(1,-1) is part of the chain) → em units, y-up.
        let toEm: (SIMD2<Real>) -> SIMD2<Real> = {
            SIMD2($0.x / unitsPerEm, -$0.y / unitsPerEm)
        }
        var glyphPaths = paths.map { $0.transformedPoints(toEm) }

        var bounds = Bounds.empty
        for path in glyphPaths {
            bounds = bounds.union(path.bounds)
        }
        let center = SIMD2<Real>(
            (bounds.min.x + bounds.max.x) / 2, (bounds.min.y + bounds.max.y) / 2
        )
        glyphPaths = glyphPaths.map { $0.translated(by: -center) }

        return glyphPaths.map { TextComponent.PositionedGlyph(path: $0, offset: .zero) }
    }

    private static func length(_ attribute: String?) -> Real {
        attribute.flatMap { Real($0) } ?? 0
    }
}

public extension TextEntity {
    /// Formula entity from MathJax tex-svg markup (the <svg> element's outer
    /// HTML, e.g. from `MathJax.tex2svg(tex)`): `scene.play(.write(formula))`
    /// writes it symbol by symbol like any text.
    static func math(
        svg: String, fontSize: Real = 1, color: Color = .white, named name: String = "Formula"
    ) throws -> TextEntity {
        let entity = TextEntity(glyphs: try MathSVG.glyphs(fromSVG: svg), fontSize: fontSize)
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

// MARK: - 2D affine transform (SVG semantics)

/// Column-major 2×3: x' = a·x + c·y + e, y' = b·x + d·y + f.
struct Affine2 {
    var a: Real = 1, b: Real = 0, c: Real = 0, d: Real = 1, e: Real = 0, f: Real = 0

    static let identity = Affine2()

    static func translation(_ t: SIMD2<Real>) -> Affine2 {
        Affine2(e: t.x, f: t.y)
    }

    func apply(_ p: SIMD2<Real>) -> SIMD2<Real> {
        SIMD2(a * p.x + c * p.y + e, b * p.x + d * p.y + f)
    }

    /// lhs ∘ rhs: rhs maps into lhs's space (parent * child).
    static func * (lhs: Affine2, rhs: Affine2) -> Affine2 {
        Affine2(
            a: lhs.a * rhs.a + lhs.c * rhs.b,
            b: lhs.b * rhs.a + lhs.d * rhs.b,
            c: lhs.a * rhs.c + lhs.c * rhs.d,
            d: lhs.b * rhs.c + lhs.d * rhs.d,
            e: lhs.a * rhs.e + lhs.c * rhs.f + lhs.e,
            f: lhs.b * rhs.e + lhs.d * rhs.f + lhs.f
        )
    }
}

extension Affine2 {
    /// Parse an SVG transform list: `translate(x[,y]) scale(s[,sy])
    /// rotate(deg[,cx,cy]) matrix(a,b,c,d,e,f)`, composed left to right.
    /// (In an extension so the struct keeps its memberwise initializer.)
    init(svgTransform: String?) {
        self = .identity
        guard let svgTransform else { return }
        var rest = Substring(svgTransform)

        while let open = rest.firstIndex(of: "(") {
            let name = rest[..<open].trimmed()
            guard let close = rest[open...].firstIndex(of: ")") else { break }
            let arguments = rest[rest.index(after: open)..<close]
                .split { $0 == "," || $0 == " " }
                .compactMap { Real(String($0)) }
            rest = rest[rest.index(after: close)...]

            switch name {
            case "translate":
                self = self * .translation(SIMD2(
                    arguments.count > 0 ? arguments[0] : 0,
                    arguments.count > 1 ? arguments[1] : 0
                ))
            case "scale":
                let sx = arguments.count > 0 ? arguments[0] : 1
                let sy = arguments.count > 1 ? arguments[1] : sx
                self = self * Affine2(a: sx, d: sy)
            case "rotate":
                let radians = (arguments.count > 0 ? arguments[0] : 0) * .pi / 180
                let rotation = Affine2(
                    a: Real.cos(radians), b: Real.sin(radians),
                    c: -Real.sin(radians), d: Real.cos(radians)
                )
                if arguments.count > 2 {
                    let pivot = SIMD2(arguments[1], arguments[2])
                    self = self * .translation(pivot) * rotation * .translation(-pivot)
                } else {
                    self = self * rotation
                }
            case "matrix":
                if arguments.count == 6 {
                    self = self * Affine2(
                        a: arguments[0], b: arguments[1], c: arguments[2],
                        d: arguments[3], e: arguments[4], f: arguments[5]
                    )
                }
            default:
                break
            }
        }
    }
}

private extension Substring {
    func trimmed() -> Substring {
        var result = self
        while let first = result.first, first == " " || first == "\t" || first == "," {
            result = result.dropFirst()
        }
        while let last = result.last, last == " " || last == "\t" {
            result = result.dropLast()
        }
        return result
    }
}

// MARK: - Tag scanner

/// Minimal markup scanner: yields opening/closing tags with attributes,
/// skips text content, comments, <!doctype> and <?...?> blocks.
struct TagScanner {
    struct Tag {
        var name: String
        var attributes: [String: String] = [:]
        var isClosing = false
        var isSelfClosing = false
    }

    private let bytes: [UInt8]
    private var index = 0

    init(_ markup: String) {
        bytes = Array(markup.utf8)
    }

    mutating func nextTag() -> Tag? {
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            index += 1
            if matches("!--") {
                skip(past: "-->")
                continue
            }
            if peek() == UInt8(ascii: "!") || peek() == UInt8(ascii: "?") {
                skip(past: ">")
                continue
            }

            var tag = Tag(name: "")
            if peek() == UInt8(ascii: "/") {
                tag.isClosing = true
                index += 1
            }
            tag.name = readName()
            if tag.isClosing {
                skip(past: ">")
                return tag
            }

            while index < bytes.count {
                skipWhitespace()
                guard let byte = peek() else { break }
                if byte == UInt8(ascii: ">") {
                    index += 1
                    break
                }
                if byte == UInt8(ascii: "/") {
                    tag.isSelfClosing = true
                    index += 1
                    continue
                }
                let attribute = readName()
                guard !attribute.isEmpty else {
                    index += 1
                    continue
                }
                skipWhitespace()
                guard peek() == UInt8(ascii: "=") else {
                    tag.attributes[attribute] = ""
                    continue
                }
                index += 1
                skipWhitespace()
                guard let quote = peek(),
                    quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'")
                else { continue }
                index += 1
                let start = index
                while index < bytes.count, bytes[index] != quote { index += 1 }
                tag.attributes[attribute] = String(decoding: bytes[start..<index], as: UTF8.self)
                if index < bytes.count { index += 1 }
            }
            return tag
        }
        return nil
    }

    private func peek() -> UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private func matches(_ text: String) -> Bool {
        let pattern = Array(text.utf8)
        guard index + pattern.count <= bytes.count else { return false }
        return Array(bytes[index..<index + pattern.count]) == pattern
    }

    private mutating func skip(past terminator: String) {
        let pattern = Array(terminator.utf8)
        while index < bytes.count {
            if matches(terminator) {
                index += pattern.count
                return
            }
            index += 1
        }
    }

    private mutating func skipWhitespace() {
        while let byte = peek(),
            byte == UInt8(ascii: " ") || byte == UInt8(ascii: "\t")
                || byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r")
        {
            index += 1
        }
    }

    /// Tag/attribute name: letters, digits, ':', '-', '_'.
    private mutating func readName() -> String {
        let start = index
        while let byte = peek() {
            let isLetter = (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
                || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            let isDigit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            let isPunctuation = byte == UInt8(ascii: ":") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
            guard isLetter || isDigit || isPunctuation else { break }
            index += 1
        }
        return String(decoding: bytes[start..<index], as: UTF8.self)
    }
}
