// IntersectionObserver → engine.setVisibility: off-screen scenes stop updating.

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
final class VisibilityObserver {
    private var closure: JSClosure?
    private var observer: JSValue = .undefined

    /// `onChange`, if given, fires alongside the engine visibility toggle on every
    /// observed change (including the initial one) — e.g. an article deck using it
    /// to defer its first reveal until it's actually scrolled into view.
    init(
        engine: Engine, canvas: JSValue, sceneID: UInt64,
        onChange: (@MainActor (Bool) -> Void)? = nil
    ) {
        let closure = JSClosure { arguments in
            let entries = arguments.first ?? .undefined
            MainActor.assumeIsolated {
                let count = Int(entries.length.number ?? 0)
                for index in 0..<count {
                    let entry = entries[index]
                    let visible = entry.isIntersecting.boolean ?? true
                    engine.setVisibility(visible, forSceneID: sceneID)
                    onChange?(visible)
                }
            }
            return .undefined
        }
        self.closure = closure

        let options: [String: JSValue] = ["threshold": .number(0.05)]
        observer = JSObject.global.IntersectionObserver.function!
            .new(closure, options.jsValue).jsValue
        _ = observer.observe(canvas)
    }
}
#endif
