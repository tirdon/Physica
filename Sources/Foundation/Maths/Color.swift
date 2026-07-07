// RGBA color. Stored as Float32 regardless of `Real` — this is GPU-facing data.

public struct Color: Sendable, Hashable, CustomDebugStringConvertible {
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(r: Float, g: Float, b: Float, a: Float = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// 0xRRGGBB with separate alpha.
    public init(hex: UInt32, alpha: Float = 1) {
        self.r = Float((hex >> 16) & 0xFF) / 255
        self.g = Float((hex >> 8) & 0xFF) / 255
        self.b = Float(hex & 0xFF) / 255
        self.a = alpha
    }

    public static let clear = Color(r: 0, g: 0, b: 0, a: 0)
    public static let black = Color(r: 0, g: 0, b: 0)
    public static let white = Color(r: 1, g: 1, b: 1)
    public static let gray = Color(hex: 0x888888)
    public static let red = Color(hex: 0xFC6255)
    public static let green = Color(hex: 0x83C167)
    public static let blue = Color(hex: 0x58C4DD)
    public static let yellow = Color(hex: 0xFFFF00)
    public static let orange = Color(hex: 0xFF862F)
    public static let purple = Color(hex: 0x9A72AC)
    public static let teal = Color(hex: 0x5CD0B3)
    public static let pink = Color(hex: 0xD147BD)
    public static let background = Color(hex: 0x16161C)
    /// The article page themes (`Document(background:)`): the warm paper white
    /// the stock stylesheet is tuned to…
    public static let documentLight = Color(hex: 0xFAF7F2)
    /// …and its dark counterpart — same value as the scene default
    /// `.background` (a separate knob on purpose), so an article page and any
    /// embedded canvases share one dark.
    public static let documentDark = Color(hex: 0x16161C)

    public func with(opacity: Float) -> Color {
        Color(r: r, g: g, b: b, a: a * opacity)
    }

    public func darker(_ amount: Float = 0.3) -> Color {
        let f = max(0, 1 - amount)
        return Color(r: r * f, g: g * f, b: b * f, a: a)
    }

    public func lighter(_ amount: Float = 0.3) -> Color {
        Color(
            r: r + (1 - r) * amount,
            g: g + (1 - g) * amount,
            b: b + (1 - b) * amount,
            a: a
        )
    }

    public static func lerp(_ from: Color, _ to: Color, _ t: Real) -> Color {
        let f = Float(t)
        return Color(
            r: from.r + (to.r - from.r) * f,
            g: from.g + (to.g - from.g) * f,
            b: from.b + (to.b - from.b) * f,
            a: from.a + (to.a - from.a) * f
        )
    }

    public var debugDescription: String {
        func channel(_ v: Float) -> String { fmt(Real(v), decimals: 2) }
        return "rgba(\(channel(r)), \(channel(g)), \(channel(b)), \(channel(a)))"
    }
}
