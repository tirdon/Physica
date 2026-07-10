// PhysicaApp — the native macOS product umbrella. One `import PhysicaApp`
// re-exports every kernel layer (mirroring `Sources/Physica/Umbrella` minus the
// browser layer), so a native app writes a single import even though the
// framework is layered underneath. PhysicaApp is the macOS sibling of
// PhysicaWeb (`Sources/WASM`): a Metal renderer, a CoreText font provider, an
// AppKit runtime, and a one-statement facade — all `#if os(macOS)`. It
// deliberately does NOT depend on PhysicaWeb (no JavaScriptKit).

@_exported import PhysicaFoundation
@_exported import PhysicaAlgebra
@_exported import PhysicaTypesetting
@_exported import PhysicaKernel
@_exported import PhysicaCharts
@_exported import PhysicaPhysics
@_exported import PhysicaEquationGame
@_exported import PhysicaArticle
