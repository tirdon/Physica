// TypeAtlas — the one place that knows which scalar the platform uses.
//
// wasm32/WASI runs Float for GPU-friendliness and size; macOS runs Double so the
// host test suite exercises the same code at higher precision. Everything else in
// the framework is written against `Real`/`Position` and never names Float/Double.

#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

#if arch(wasm32) || os(WASI)
public typealias Real = Float
#else
public typealias Real = Double
#endif

public typealias Position = SIMD3<Real>
public typealias TimeInterval = Real

// MARK: - libm shims
// Centralized so no other file needs conditional libc imports. Qualified names
// avoid recursing into these same static wrappers.

extension Real {
    @_transparent public static func sin(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return sinf(x)
        #elseif canImport(Darwin)
        return Darwin.sin(x)
        #else
        return Glibc.sin(x)
        #endif
    }

    @_transparent public static func cos(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return cosf(x)
        #elseif canImport(Darwin)
        return Darwin.cos(x)
        #else
        return Glibc.cos(x)
        #endif
    }

    @_transparent public static func tan(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return tanf(x)
        #elseif canImport(Darwin)
        return Darwin.tan(x)
        #else
        return Glibc.tan(x)
        #endif
    }

    @_transparent public static func asin(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return asinf(x)
        #elseif canImport(Darwin)
        return Darwin.asin(x)
        #else
        return Glibc.asin(x)
        #endif
    }

    @_transparent public static func acos(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return acosf(x)
        #elseif canImport(Darwin)
        return Darwin.acos(x)
        #else
        return Glibc.acos(x)
        #endif
    }

    @_transparent public static func atan2(_ y: Real, _ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return atan2f(y, x)
        #elseif canImport(Darwin)
        return Darwin.atan2(y, x)
        #else
        return Glibc.atan2(y, x)
        #endif
    }

    @_transparent public static func pow(_ base: Real, _ exponent: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return powf(base, exponent)
        #elseif canImport(Darwin)
        return Darwin.pow(base, exponent)
        #else
        return Glibc.pow(base, exponent)
        #endif
    }

    @_transparent public static func exp(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return expf(x)
        #elseif canImport(Darwin)
        return Darwin.exp(x)
        #else
        return Glibc.exp(x)
        #endif
    }

    @_transparent public static func log(_ x: Real) -> Real {
        #if arch(wasm32) || os(WASI)
        return logf(x)
        #elseif canImport(Darwin)
        return Darwin.log(x)
        #else
        return Glibc.log(x)
        #endif
    }

    @_transparent public static func sqrt(_ x: Real) -> Real { x.squareRoot() }

    public static let pi = Real(Double.pi)
    public static let tau = Real(2 * Double.pi)
}

// MARK: - Stable debug formatting
// debugString output must be identical for Float (wasm) and Double (macOS), so all
// formatting goes through this fixed-decimal renderer built on integer math.

/// Formats `value` with exactly `decimals` fraction digits, no scientific notation,
/// normalizing negative zero. The backbone of every `debugString` in the framework.
public func fmt(_ value: Real, decimals: Int = 3) -> String {
    if value.isNaN { return "nan" }
    if value.isInfinite { return value > 0 ? "inf" : "-inf" }

    var scale = 1.0
    for _ in 0..<decimals { scale *= 10 }
    var scaled = (Double(value) * scale).rounded()
    if scaled == 0 { scaled = 0 }  // collapse -0
    let negative = scaled < 0
    let units = UInt64(Swift.abs(scaled))
    let whole = units / UInt64(scale)
    let fraction = units % UInt64(scale)

    var fractionDigits = String(fraction)
    while fractionDigits.count < decimals { fractionDigits = "0" + fractionDigits }

    let sign = negative ? "-" : ""
    return decimals == 0 ? "\(sign)\(whole)" : "\(sign)\(whole).\(fractionDigits)"
}

/// Formats a vector as `(x, y, z)` with stable decimals.
public func fmt(_ v: Position, decimals: Int = 3) -> String {
    "(\(fmt(v.x, decimals: decimals)), \(fmt(v.y, decimals: decimals)), \(fmt(v.z, decimals: decimals)))"
}
