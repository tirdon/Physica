import Testing
@testable import Physica

func approx(_ a: Real, _ b: Real, tolerance: Real = 1e-4) -> Bool {
    Swift.abs(a - b) <= tolerance
}

func approx(_ a: Position, _ b: Position, tolerance: Real = 1e-4) -> Bool {
    approx(a.x, b.x, tolerance: tolerance)
        && approx(a.y, b.y, tolerance: tolerance)
        && approx(a.z, b.z, tolerance: tolerance)
}

@Suite struct MathTests {
    @Test func vectorSugar() {
        #expect(1.i + 2.j == Position(1, 2, 0))
        #expect(0.5.k == Position(0, 0, 0.5))
        #expect(Position.origin == .zero)
        #expect((3.i).length == 3)
        #expect(approx(Position(1, 1, 0).normalized.length, 1))
        #expect(1.i.cross(1.j) == 1.k)
        #expect(Position(1, 2, 3).dot(Position(4, 5, 6)) == 32)
    }

    @Test func durationSugar() {
        #expect(2.s.interval == 2)
        #expect(approx(0.25.s.interval, 0.25))
        #expect(approx(Duration.interval(1.5).interval, 1.5))
    }

    @Test func fmtStability() {
        #expect(fmt(1.0 / 3.0) == "0.333")
        #expect(fmt(2) == "2.000")
        #expect(fmt(-1.5) == "-1.500")
        #expect(fmt(-0.0001) == "0.000")
        #expect(fmt(0.6666, decimals: 2) == "0.67")
        #expect(fmt(5, decimals: 0) == "5")
        #expect(fmt(Position(1, -2, 0.5)) == "(1.000, -2.000, 0.500)")
    }

    @Test func quaternionRotation() {
        let quarterTurn = Quaternion(angle: .pi / 2, axis: 1.k)
        #expect(approx(quarterTurn.act(1.i), 1.j))
        #expect(approx(Quaternion.identity.act(Position(3, -2, 1)), Position(3, -2, 1)))

        let composed = quarterTurn * quarterTurn
        #expect(approx(composed.act(1.i), -1.i))
        #expect(approx(quarterTurn.inverse.act(1.j), 1.i))
    }

    @Test func quaternionSlerp() {
        let halfTurn = Quaternion(angle: .pi, axis: 1.k)
        let mid = Quaternion.slerp(.identity, halfTurn, 0.5)
        #expect(approx(mid.act(1.i), 1.j))
        #expect(approx(Quaternion.slerp(.identity, halfTurn, 0).act(1.i), 1.i))
    }

    @Test func orthographicProjection() {
        let m = Matrix4.orthographic(left: -2, right: 2, bottom: -1, top: 1, near: 0.1, far: 10)
        #expect(approx(m.transformPoint(Position(2, 1, -0.1)), Position(1, 1, 0)))
        #expect(approx(m.transformPoint(Position(-2, -1, -10)), Position(-1, -1, 1)))
        #expect(approx(m.transformPoint(Position(0, 0, -0.1)), Position(0, 0, 0)))
    }

    @Test func perspectiveProjection() {
        let m = Matrix4.perspective(fovYRadians: .pi / 2, aspect: 1, near: 1, far: 10)
        #expect(approx(m.project(Position(0, 0, -1)).z, 0))
        #expect(approx(m.project(Position(0, 0, -10)).z, 1))
        #expect(approx(m.project(Position(1, 1, -1)), Position(1, 1, 0)))
    }

    @Test func trsComposition() {
        let m = Matrix4.trs(
            translation: Position(1, 2, 3),
            rotation: Quaternion(angle: .pi / 2, axis: 1.k),
            scale: SIMD3(2, 2, 2)
        )
        #expect(approx(m.transformPoint(1.i), Position(1, 4, 3)))
    }

    @Test func rigidInverse() {
        let look = Matrix4.lookAt(eye: Position(0, 0, 5), target: .origin, up: 1.j)
        #expect(approx(look.transformPoint(.origin), Position(0, 0, -5)))
        let roundTrip = look.rigidInverse * look
        #expect(approx(roundTrip.transformPoint(Position(1, 2, 3)), Position(1, 2, 3)))
    }

    @Test func easingEndpoints() {
        let curves: [Easing] = [
            .linear, .easeIn, .easeOut, .easeInOut, .smooth, .doubleSmooth,
            .sigmoid(steepness: 10), .expoIn, .expoOut, .elasticIn, .elasticOut,
            .bounce, .spring(damping: 10, stiffness: 100),
        ]
        for curve in curves {
            #expect(approx(curve.apply(0), 0, tolerance: 1e-3))
            #expect(approx(curve.apply(1), 1, tolerance: 1e-3))
        }
        #expect(approx(Easing.wiggle(oscillations: 3).apply(1), 0))
        #expect(approx(Easing.smooth.apply(0.5), 0.5))
    }

    @Test func colorBasics() {
        #expect(Color(hex: 0xFF0000).r == 1)
        #expect(Color(hex: 0x00FF00).g == 1)
        let mid = Color.lerp(.black, .white, 0.5)
        #expect(approx(Real(mid.r), 0.5, tolerance: 1e-3))
        #expect(Color.red.with(opacity: 0.5).a == 0.5)
        #expect(Color.white.debugDescription == "rgba(1.00, 1.00, 1.00, 1.00)")
    }

    @Test func unitVectors() {
        #expect(Unit.top.vector == Position(0, 1, 0))
        #expect(Unit.bottomLeft.vector == Position(-1, -1, 0))
        #expect(Unit.ceiling == .top)
        #expect(Unit.center.vector == .zero)
    }

    @Test func interpolatable() {
        #expect(Real.lerp(0, 10, 0.3) == 3)
        #expect(Position.lerp(.origin, Position(2, 4, 6), 0.5) == Position(1, 2, 3))
    }
}
