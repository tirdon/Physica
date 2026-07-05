// WASM — the product umbrella. One `import WASM` re-exports the browser layer
// (`PhysicaWeb`): the WebGPU renderer, the DOM runtimes, and the document DSL.
// Every file behind it is `#if os(WASI)`, so a host build re-exports an empty
// module. Consumers who want the whole framework import `Physica` instead.

@_exported import PhysicaWeb
