// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Physica",
	platforms: [.macOS(.v26)],
	products: [
		.library(name: "Physica", targets: ["Physica"]),
		// Example executables live under Sources/PhysicaDemo/{Example0,Example1}.
		// SwiftPM exposes an implicit executable product for each, so
		// PackageToJS can target them with `--product Example1` / `--product Example0`.
	],
	dependencies: [.package(url: "https://github.com/swiftwasm/JavaScriptKit.git", branch: "main" )],
    targets: [
		// Layered library targets (REDESIGN.md Phase 5): directories ARE the
		// layers, the compiler enforces the DAG, and the `Physica` umbrella
		// re-exports everything so consumers keep a single `import Physica`.
		// Phase 1 of the three-product redesign relocated these directories to
		// the new tree (Foundation / Typesetting / Physica / WASM); the target
		// NAMES are unchanged, so per-file imports stay valid.
		.target(name: "PhysicaMath", path: "Sources/Foundation/Maths"),
		.target(name: "PhysicaAlgebra", path: "Sources/Typesetting/Algebra"),
		.target(
			name: "PhysicaGeometry",
			dependencies: ["PhysicaMath"],
			path: "Sources/Foundation/Geometry"
		),
		.target(
			name: "PhysicaTypesetting",
			dependencies: ["PhysicaMath", "PhysicaGeometry"],
			path: "Sources/Typesetting",
			exclude: ["Algebra"]
		),
		// The mutually-coupled core: object model + animation machinery +
		// scene/camera/snapshot + entity kinds + interaction. One target on
		// purpose — Scene and Animation call into each other by design.
		.target(
			name: "PhysicaKernel",
			// Algebra rides in for the drag vocabulary (DragPayload carries
			// Expression/ProjectionAxis) — a pre-existing domain edge.
			dependencies: ["PhysicaMath", "PhysicaAlgebra", "PhysicaGeometry", "PhysicaTypesetting"],
			path: "Sources/Physica",
			sources: ["Animation", "ECS", "Interactions", "Storytelling"]
		),
		.target(
			name: "PhysicaPlotting",
			dependencies: ["PhysicaMath", "PhysicaGeometry", "PhysicaTypesetting", "PhysicaKernel"],
			path: "Sources/Physica/Charts/Plotting"
		),
		.target(
			name: "PhysicaStory",
			dependencies: ["PhysicaMath", "PhysicaGeometry", "PhysicaKernel"],
			path: "Sources/Physica/Story"
		),
		.target(
			name: "PhysicaPhysics",
			dependencies: ["PhysicaMath", "PhysicaGeometry", "PhysicaKernel"],
			path: "Sources/Physica/Helpers/Physics"
		),
		.target(
			name: "PhysicaEquationGame",
			dependencies: ["PhysicaMath", "PhysicaAlgebra", "PhysicaGeometry", "PhysicaTypesetting", "PhysicaKernel"],
			path: "Sources/Physica/EquationGame"
		),
		// Browser glue + WebGPU renderer — every file `#if os(WASI)`; the sole
		// JavaScriptKit dependency, still conditional so host builds stay clean.
		.target(
			name: "PhysicaWeb",
			dependencies: [
				"PhysicaMath", "PhysicaAlgebra", "PhysicaGeometry", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaPlotting", "PhysicaStory", "PhysicaPhysics",
				"PhysicaEquationGame",
				.product(
					name: "JavaScriptKit", package: "JavaScriptKit",
					condition: .when(platforms: [.wasi])
				),
				.product(
					name: "JavaScriptEventLoop", package: "JavaScriptKit",
					condition: .when(platforms: [.wasi])
				),
			],
			path: "Sources/WASM"
		),
		// Umbrella: `@_exported import` of every layer.
		.target(
			name: "Physica",
			dependencies: [
				"PhysicaMath", "PhysicaAlgebra", "PhysicaGeometry", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaPlotting", "PhysicaStory", "PhysicaPhysics",
				"PhysicaEquationGame", "PhysicaWeb",
			],
			path: "Sources/Physica/Umbrella"
		),
        .testTarget(
            name: "PhysicaTests",
            dependencies: [
				"Physica",
				"PhysicaMath", "PhysicaAlgebra", "PhysicaGeometry", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaPlotting", "PhysicaStory", "PhysicaPhysics",
				"PhysicaEquationGame",
			]
        ),

		// Examples — each a standalone wasm executable under Sources/PhysicaDemo/.
        .executableTarget(
            name: "Example1",
			dependencies: [
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
				.target(name: "Physica")
				],
			path: "Sources/PhysicaDemo/Example1",
			plugins: [
				.plugin(name: "BridgeJS", package: "JavaScriptKit")
			]
        ),
        .executableTarget(
            name: "Example2",
			dependencies: [
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
				.target(name: "Physica")
				],
			path: "Sources/PhysicaDemo/Example2"
        ),
        .executableTarget(
            name: "Example0",
			dependencies: [
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
				.target(name: "Physica")
				],
			path: "Sources/PhysicaDemo/Example0"
        ),
			// Example3 — a Medium-style scientific article rendered to the browser
			// DOM (no WebGPU scene): a declarative result-builder DSL over a pure
			// value document model, walked by a WASI-only DOM renderer. Own bundle
			// dir js-example3/, shell example3.html, GPU-free check smoke-example3.mjs.
        .executableTarget(
            name: "Example3",
				dependencies: [
					.product(name: "JavaScriptKit", package: "JavaScriptKit"),
					.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
					.target(name: "Physica")
					],
				path: "Sources/PhysicaDemo/Example3"
        ),

			// Story Studio — a standalone wasm WYSIWYG storytelling-authoring app
			// (its own scene + bundle dir js-studio/, shell studio.html). Clones the
			// Example0 stanza; the editor's Document/Compiler/History are platform-
			// neutral (host-typechecked + unit-tested), only its entry/runtime is WASI.
        .executableTarget(
            name: "StoryStudio",
				dependencies: [
					.product(name: "JavaScriptKit", package: "JavaScriptKit"),
					.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
					.target(name: "Physica")
					]
        ),
        .testTarget(
            name: "StoryStudioTests",
            dependencies: ["StoryStudio"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
