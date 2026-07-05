// requestAnimationFrame loop driving Engine.tick with clamped deltas.

import PhysicaFoundation
import PhysicaAlgebra
import PhysicaTypesetting
import PhysicaKernel
import PhysicaCharts
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
final class RAFDriver {
    private var closure: JSClosure?
    private var lastTimestampMS: Double?

    func start(_ tick: @escaping @MainActor (TimeInterval) -> Void) {
        let closure = JSClosure { [weak self] arguments in
            let timestamp = arguments.first?.number ?? 0
            MainActor.assumeIsolated {
                guard let self else { return }
                let deltaMS = self.lastTimestampMS.map { timestamp - $0 } ?? 16.7
                self.lastTimestampMS = timestamp
                // Clamp: background tabs / debugger pauses must not explode physics.
                let delta = min(max(deltaMS / 1000, 0), 0.05)
                tick(TimeInterval(delta))
                if let next = self.closure {
                    _ = JSObject.global.requestAnimationFrame!(next)
                }
            }
            return .undefined
        }
        self.closure = closure
        _ = JSObject.global.requestAnimationFrame!(closure)
    }

    func stop() {
        closure = nil
    }
}
#endif
