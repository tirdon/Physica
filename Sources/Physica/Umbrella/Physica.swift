// Physica — the umbrella module. One `import Physica` re-exports every layer
// target, so consumers (demos, StoryStudio, external packages) never name the
// layers; the split exists to make the layering compiler-enforced, not to
// change the import story. Layer DAG: Math and Algebra are leaves; Geometry
// and Typesetting are pure value layers; Kernel is the mutually-coupled core
// (ECS + Animation + Scene + Entities + Interaction); Plotting/Story/Physics/
// EquationGame are domains on top; Web is the `#if os(WASI)` browser glue.

@_exported import PhysicaMath
@_exported import PhysicaAlgebra
@_exported import PhysicaGeometry
@_exported import PhysicaTypesetting
@_exported import PhysicaKernel
@_exported import PhysicaPlotting
@_exported import PhysicaStory
@_exported import PhysicaPhysics
@_exported import PhysicaEquationGame
@_exported import PhysicaWeb
