// IntersectionObserver → engine.setVisibility: off-screen scenes stop updating.

import PhysicaMath
import PhysicaAlgebra
import PhysicaGeometry
import PhysicaTypesetting
import PhysicaKernel
import PhysicaPlotting
import PhysicaStory
import PhysicaPhysics
import PhysicaEquationGame

#if os(WASI)
import JavaScriptKit

@MainActor
final class VisibilityObserver {
    private var closure: JSClosure?
    private var observer: JSValue = .undefined

    init(engine: Engine, canvas: JSValue, sceneID: UInt64) {
        let closure = JSClosure { arguments in
            let entries = arguments.first ?? .undefined
            MainActor.assumeIsolated {
                let count = Int(entries.length.number ?? 0)
                for index in 0..<count {
                    let entry = entries[index]
                    let visible = entry.isIntersecting.boolean ?? true
                    engine.setVisibility(visible, forSceneID: sceneID)
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
