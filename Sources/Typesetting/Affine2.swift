// Affine2 — column-major 2×3 affine transform with SVG matrix/translate/scale/
// rotate semantics, applied while walking MathJax SVG. See MathSVG.swift.

// MARK: - 2D affine transform (SVG semantics)

/// Column-major 2×3: x' = a·x + c·y + e, y' = b·x + d·y + f.
import PhysicaFoundation

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
