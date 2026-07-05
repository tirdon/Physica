// SVG path-data ("d" attribute) → Path. MathJax glyph outlines and any other
// SVG asset lower into Path through this parser; it speaks the full command
// set (M/L/H/V/C/S/Q/T/A/Z, absolute and relative, implicit repeats).


public enum SVGPathError: Error, Equatable, Sendable {
    case unexpectedCharacter(Character)
    case malformedNumber
    /// Path data must start with a moveto command.
    case missingMoveTo
}

public extension Path {
    /// Parse SVG path data: `Path.svg("M 0 0 L 10 0 Q 15 5 10 10 Z")`.
    /// Coordinates pass through untouched — SVG's y-down convention is the
    /// caller's concern (MathSVG flips when mapping into world space).
    static func svg(_ data: String) throws -> Path {
        var parser = SVGPathParser(data)
        return try parser.parse()
    }
}

private struct SVGPathParser {
    private let bytes: [UInt8]
    private var index = 0

    private var contours: [Path.Contour] = []
    private var contour: Path.Contour?
    private var current = SIMD2<Real>(0, 0)
    private var subpathStart = SIMD2<Real>(0, 0)
    /// Reflection state for S/T smooth commands.
    private var lastCubicControl: SIMD2<Real>?
    private var lastQuadControl: SIMD2<Real>?

    init(_ data: String) {
        bytes = Array(data.utf8)
    }

    mutating func parse() throws -> Path {
        var command: UInt8?
        while true {
            skipSeparators()
            guard index < bytes.count else { break }
            let byte = bytes[index]
            if isCommandLetter(byte) {
                command = byte
                index += 1
            } else if !isNumberStart(byte)
                || command == UInt8(ascii: "Z") || command == UInt8(ascii: "z") {
                // Stray character, or numbers after Z (Z takes no repeats —
                // without this guard the loop would never advance).
                throw SVGPathError.unexpectedCharacter(Character(UnicodeScalar(byte)))
            }
            // else: a number repeats the previous command (M's repeats are linetos).
            guard let active = command else { throw SVGPathError.missingMoveTo }
            command = try run(active)
        }
        finishContour()
        return Path(contours: contours)
    }

    /// Execute one command (one argument group); returns the command that
    /// implicit repeats should run (M → L per the SVG spec).
    private mutating func run(_ command: UInt8) throws -> UInt8 {
        let relative = command >= UInt8(ascii: "a")  // lowercase
        let letter = relative ? command - (UInt8(ascii: "a") - UInt8(ascii: "A")) : command
        var nextControlCubic: SIMD2<Real>?
        var nextControlQuad: SIMD2<Real>?
        var next = command

        switch letter {
        case UInt8(ascii: "M"):
            finishContour()
            current = try point(relative: relative)
            subpathStart = current
            contour = Path.Contour(start: current)
            next = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")

        case UInt8(ascii: "L"):
            try lineTo(point(relative: relative))

        case UInt8(ascii: "H"):
            let x = try number()
            try lineTo(SIMD2(relative ? current.x + x : x, current.y))

        case UInt8(ascii: "V"):
            let y = try number()
            try lineTo(SIMD2(current.x, relative ? current.y + y : y))

        case UInt8(ascii: "C"):
            let c1 = try point(relative: relative)
            let c2 = try point(relative: relative)
            let to = try point(relative: relative)
            try append(.curve(control1: c1, control2: c2, to: to))
            nextControlCubic = c2
            current = to

        case UInt8(ascii: "S"):
            let c1 = lastCubicControl.map { 2 * current - $0 } ?? current
            let c2 = try point(relative: relative)
            let to = try point(relative: relative)
            try append(.curve(control1: c1, control2: c2, to: to))
            nextControlCubic = c2
            current = to

        case UInt8(ascii: "Q"):
            let control = try point(relative: relative)
            let to = try point(relative: relative)
            try append(.quadCurve(control: control, to: to))
            nextControlQuad = control
            current = to

        case UInt8(ascii: "T"):
            let control = lastQuadControl.map { 2 * current - $0 } ?? current
            let to = try point(relative: relative)
            try append(.quadCurve(control: control, to: to))
            nextControlQuad = control
            current = to

        case UInt8(ascii: "A"):
            let radii = try SIMD2(number(), number())
            let rotation = try number() * .pi / 180
            let largeArc = try flag()
            let sweep = try flag()
            let to = try point(relative: relative)
            try arcTo(to, radii: radii, rotation: rotation, largeArc: largeArc, sweep: sweep)

        case UInt8(ascii: "Z"):
            contour?.isClosed = true
            finishContour()
            current = subpathStart

        default:
            throw SVGPathError.unexpectedCharacter(Character(UnicodeScalar(command)))
        }

        lastCubicControl = nextControlCubic
        lastQuadControl = nextControlQuad
        return next
    }

    // MARK: Segment plumbing

    private mutating func lineTo(_ to: SIMD2<Real>) throws {
        try append(.line(to: to))
        current = to
    }

    private mutating func append(_ segment: Path.Segment) throws {
        if contour == nil {
            // Drawing after Z without a fresh M: new subpath at the close point.
            guard !contours.isEmpty else { throw SVGPathError.missingMoveTo }
            contour = Path.Contour(start: current)
        }
        contour?.segments.append(segment)
    }

    private mutating func finishContour() {
        if let finished = contour, !finished.segments.isEmpty {
            contours.append(finished)
        }
        contour = nil
    }

    /// Elliptical arc → cubic Béziers (endpoint → center form, SVG spec F.6.5,
    /// then ≤90° slices with the 4/3·tan(θ/4) control distance).
    private mutating func arcTo(
        _ to: SIMD2<Real>, radii: SIMD2<Real>, rotation: Real, largeArc: Bool, sweep: Bool
    ) throws {
        guard radii.x != 0, radii.y != 0, to != current else {
            return try lineTo(to)
        }
        var rx = Swift.abs(radii.x)
        var ry = Swift.abs(radii.y)
        let cosR = Real.cos(rotation)
        let sinR = Real.sin(rotation)

        let half = (current - to) / 2
        let p = SIMD2(cosR * half.x + sinR * half.y, -sinR * half.x + cosR * half.y)
        // Scale radii up if the endpoints can't be reached.
        let lambda = (p.x * p.x) / (rx * rx) + (p.y * p.y) / (ry * ry)
        if lambda > 1 {
            let s = Real.sqrt(lambda)
            rx *= s
            ry *= s
        }

        let rxry = rx * rx * ry * ry
        let rxpy = rx * rx * p.y * p.y
        let rypx = ry * ry * p.x * p.x
        let radicand = Swift.max((rxry - rxpy - rypx) / (rxpy + rypx), 0)
        var scale = Real.sqrt(radicand)
        if largeArc == sweep { scale = -scale }
        let centerP = SIMD2(scale * rx * p.y / ry, -scale * ry * p.x / rx)
        let center = SIMD2(
            cosR * centerP.x - sinR * centerP.y + (current.x + to.x) / 2,
            sinR * centerP.x + cosR * centerP.y + (current.y + to.y) / 2
        )

        func angle(_ v: SIMD2<Real>) -> Real { Real.atan2(v.y, v.x) }
        let startVector = SIMD2((p.x - centerP.x) / rx, (p.y - centerP.y) / ry)
        let endVector = SIMD2((-p.x - centerP.x) / rx, (-p.y - centerP.y) / ry)
        let startAngle = angle(startVector)
        var delta = angle(endVector) - startAngle
        if sweep, delta < 0 { delta += 2 * .pi }
        if !sweep, delta > 0 { delta -= 2 * .pi }

        let sliceCount = Swift.max(1, Int((Swift.abs(delta) / (Real.pi / 2)).rounded(.up)))
        let step = delta / Real(sliceCount)
        let control = 4 / 3 * Real.tan(step / 4)

        func onArc(_ theta: Real) -> (point: SIMD2<Real>, derivative: SIMD2<Real>) {
            let cosT = Real.cos(theta)
            let sinT = Real.sin(theta)
            let point = SIMD2(
                center.x + rx * cosT * cosR - ry * sinT * sinR,
                center.y + rx * cosT * sinR + ry * sinT * cosR
            )
            let derivative = SIMD2(
                -rx * sinT * cosR - ry * cosT * sinR,
                -rx * sinT * sinR + ry * cosT * cosR
            )
            return (point, derivative)
        }

        for slice in 0..<sliceCount {
            let a0 = startAngle + Real(slice) * step
            let a1 = a0 + step
            let from = onArc(a0)
            let toPoint = onArc(a1)
            try append(.curve(
                control1: from.point + control * from.derivative,
                control2: toPoint.point - control * toPoint.derivative,
                to: slice == sliceCount - 1 ? to : toPoint.point  // land exactly
            ))
        }
        current = to
    }

    // MARK: Scanning

    private mutating func point(relative: Bool) throws -> SIMD2<Real> {
        let parsed = try SIMD2(number(), number())
        return relative ? current + parsed : parsed
    }

    private mutating func flag() throws -> Bool {
        skipSeparators()
        guard index < bytes.count else { throw SVGPathError.malformedNumber }
        switch bytes[index] {
        case UInt8(ascii: "0"): index += 1; return false
        case UInt8(ascii: "1"): index += 1; return true
        default: throw SVGPathError.malformedNumber
        }
    }

    private mutating func number() throws -> Real {
        skipSeparators()
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        var hasDigits = false
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
            hasDigits = true
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            while index < bytes.count, isDigit(bytes[index]) {
                index += 1
                hasDigits = true
            }
        }
        guard hasDigits else { throw SVGPathError.malformedNumber }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard index < bytes.count, isDigit(bytes[index]) else { throw SVGPathError.malformedNumber }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        guard let value = Real(String(decoding: bytes[start..<index], as: UTF8.self)) else {
            throw SVGPathError.malformedNumber
        }
        return value
    }

    private mutating func skipSeparators() {
        while index < bytes.count, isSeparator(bytes[index]) { index += 1 }
    }

    private func isSeparator(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: " ") || byte == UInt8(ascii: ",") || byte == UInt8(ascii: "\n")
            || byte == UInt8(ascii: "\t") || byte == UInt8(ascii: "\r")
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private func isNumberStart(_ byte: UInt8) -> Bool {
        isDigit(byte) || byte == UInt8(ascii: "+") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }

    private func isCommandLetter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "M"), UInt8(ascii: "m"), UInt8(ascii: "L"), UInt8(ascii: "l"),
             UInt8(ascii: "H"), UInt8(ascii: "h"), UInt8(ascii: "V"), UInt8(ascii: "v"),
             UInt8(ascii: "C"), UInt8(ascii: "c"), UInt8(ascii: "S"), UInt8(ascii: "s"),
             UInt8(ascii: "Q"), UInt8(ascii: "q"), UInt8(ascii: "T"), UInt8(ascii: "t"),
             UInt8(ascii: "A"), UInt8(ascii: "a"), UInt8(ascii: "Z"), UInt8(ascii: "z"):
            return true
        default:
            return false
        }
    }
}
