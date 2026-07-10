// Physica — the umbrella for the `Physica` product. One `import Physica`
// re-exports every layer, so consumers (demos, StoryStudio, external packages)
// keep a single import even though the framework is three products underneath
// (Physica / Typesetting / WASM). Layer DAG: Foundation (Maths + Geometry) and
// Algebra are the shared leaves; Typesetting (Font/MathSVG parsers) sits on
// Foundation; Kernel is the mutually-coupled core (ECS + Animation +
// Storytelling[Scene/Camera/Timeline/Story] + Entities + Interactions);
// Charts / Physics / EquationGame are domains on top; Web is the
// `#if os(WASI)` browser glue (renderer + runtimes + document DSL + facade).

@_exported import PhysicaFoundation
@_exported import PhysicaAlgebra
@_exported import PhysicaTypesetting
@_exported import PhysicaKernel
@_exported import PhysicaCharts
@_exported import PhysicaPhysics
@_exported import PhysicaEquationGame
@_exported import PhysicaArticle
@_exported import PhysicaWeb
