// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Physica",
	platforms: [.macOS(.v26)],
	products: [
		// Three separately-importable products. `Physica` re-exports the whole
		// framework (incl. the browser layer), so consumers keep one `import
		// Physica`; `Typesetting` and `WASM` name the reusable sub-stacks.
		.library(name: "Physica", targets: ["Physica"]),
		.library(name: "Typesetting", targets: ["Typesetting"]),
		.library(name: "WASM", targets: ["WASM"]),
		// Native macOS presentation stack (Metal renderer + CoreText fonts +
		// AppKit runtime + facade) — the sibling of `WASM`, on the same kernel
		// layers, with no JavaScriptKit dependency.
		.library(name: "PhysicaApp", targets: ["PhysicaApp"]),
	],
	dependencies: [.package(url: "https://github.com/swiftwasm/JavaScriptKit.git", branch: "main" )],
    targets: [
		// ---- Foundation (shared leaf: numeric atlas + geometry values) --------
		// Below the Physica<->Typesetting cut so both can depend on it without a
		// cycle. Maths (Real/quat/matrix/color/easing) + Geometry (Path/Mesh).
		.target(
			name: "PhysicaFoundation",
			path: "Sources/Foundation",
			sources: ["Maths", "Geometry"]
		),

		// ---- Typesetting product (Algebra + Font/MathSVG parsers + Literals) --
		.target(name: "PhysicaAlgebra", path: "Sources/Typesetting/Algebra"),
		.target(
			name: "PhysicaTypesetting",
			dependencies: ["PhysicaFoundation"],
			path: "Sources/Typesetting",
			exclude: ["Algebra", "Umbrella"]
		),
		.target(
			name: "Typesetting",
			dependencies: ["PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting"],
			path: "Sources/Typesetting/Umbrella"
		),

		// ---- Physica product --------------------------------------------------
		// The mutually-coupled core: object model + animation machinery +
		// scene/camera/snapshot/story + entity kinds + interaction. One target on
		// purpose — Scene, Animation and Story call into each other by design.
		.target(
			name: "PhysicaKernel",
			// Algebra rides in for the drag vocabulary (DragPayload carries
			// Expression/ProjectionAxis) — a pre-existing domain edge.
			dependencies: ["PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting"],
			path: "Sources/Physica",
			exclude: ["Charts", "Helpers", "EquationGame", "Umbrella"],
			sources: ["Animation", "ECS", "Interactions", "Storytelling"]
		),
		.target(
			name: "PhysicaCharts",
			dependencies: ["PhysicaFoundation", "PhysicaTypesetting", "PhysicaKernel"],
			path: "Sources/Physica/Charts"
		),
		.target(
			name: "PhysicaPhysics",
			dependencies: ["PhysicaFoundation", "PhysicaKernel"],
			path: "Sources/Physica/Helpers/Physics"
		),
		.target(
			name: "PhysicaEquationGame",
			dependencies: ["PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting", "PhysicaKernel"],
			path: "Sources/Physica/EquationGame"
		),

		// ---- PhysicaArticle (the document model + static HTML serializer) ------
		// The platform-neutral article layer: the `Document` DSL/value model,
		// the stylesheet, the plain-text outline, and `ArticleHTML` (Document →
		// one self-contained HTML string). NO JavaScriptKit, so both the WASI DOM
		// renderer (PhysicaWeb) and the native writer (PhysicaApp) depend on it.
		.target(
			name: "PhysicaArticle",
			dependencies: ["PhysicaFoundation", "PhysicaKernel"],
			path: "Sources/Article"
		),

		// Umbrella: `@_exported import` of every layer.
		.target(
			name: "Physica",
			dependencies: [
				"PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaCharts", "PhysicaPhysics",
				"PhysicaEquationGame", "PhysicaArticle", "PhysicaWeb",
			],
			path: "Sources/Physica/Umbrella"
		),

		// ---- WASM product (browser glue + WebGPU renderer + document DSL) -----
		// Every Swift file here is `#if os(WASI)`. The JavaScriptKit dependency
		// is unconditional (not `.when(.wasi)`) because the BridgeJS plugin's
		// generated glue imports it on every platform (its host stubs
		// fatalError); the demos already depend on JSKit unconditionally, so
		// this adds nothing new to the host build graph.
		.target(
			name: "PhysicaWeb",
			dependencies: [
				"PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaCharts", "PhysicaPhysics", "PhysicaEquationGame",
				"PhysicaArticle",
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
			],
			path: "Sources/WASM",
			exclude: ["Umbrella"],
			// BridgeJS pilot (FontLoader): the @JSGetter/@JSClass/@JSFunction
			// macros expand to @_extern(wasm) thunks the plugin generates —
			// both the feature flag and the plugin are required on any target
			// that uses them.
			swiftSettings: [.enableExperimentalFeature("Extern")],
			plugins: [.plugin(name: "BridgeJS", package: "JavaScriptKit")]
		),
		.target(
			name: "WASM",
			dependencies: ["PhysicaWeb"],
			path: "Sources/WASM/Umbrella"
		),

		// ---- PhysicaApp product (native macOS: Metal + CoreText + AppKit) -----
		// Every Swift file here is `#if os(macOS)` (the umbrella re-exports are
		// the exception). Depends on the kernel layers directly — NOT on
		// `Physica`/`PhysicaWeb`, so JavaScriptKit never enters the graph.
		.target(
			name: "PhysicaApp",
			dependencies: [
				"PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaCharts", "PhysicaPhysics", "PhysicaEquationGame",
				"PhysicaArticle",
			],
			path: "Sources/PhysicaApp"
		),

        .testTarget(
            name: "PhysicaTests",
            dependencies: [
				"Physica",
				"PhysicaFoundation", "PhysicaAlgebra", "PhysicaTypesetting",
				"PhysicaKernel", "PhysicaCharts", "PhysicaPhysics", "PhysicaEquationGame",
				"PhysicaArticle",
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
			path: "Sources/PhysicaDemo/Example1"
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

			// Native macOS demo executables on the Metal/CoreText/AppKit stack,
			// each its own bundle under Sources/MetalApp/. AppExample0 opens the
			// pendulum window (`swift run AppExample0`); AppExample1 writes the
			// Document DSL to a single HTML file (`swift run AppExample1` →
			// article.html) — the native sibling of the wasm Example3.
        .executableTarget(
            name: "AppExample0",
				dependencies: ["PhysicaApp"],
				path: "Sources/MetalApp/AppExample0"
        ),
        .executableTarget(
            name: "AppExample1",
				dependencies: ["PhysicaApp"],
				path: "Sources/MetalApp/AppExample1"
        ),
        .testTarget(
            name: "PhysicaAppTests",
            dependencies: ["PhysicaApp", "PhysicaTypesetting"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
