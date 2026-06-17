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
		// Core stays dependency-free on host platforms; the WASM/ subtree
		// (renderer + browser glue, all `#if os(WASI)`) links JavaScriptKit
		// only when building for wasm.
		.target(
			name: "Physica",
			dependencies: [
				.product(
					name: "JavaScriptKit", package: "JavaScriptKit",
					condition: .when(platforms: [.wasi])
				),
				.product(
					name: "JavaScriptEventLoop", package: "JavaScriptKit",
					condition: .when(platforms: [.wasi])
				),
			]
		),
        .testTarget(
            name: "PhysicaTests",
            dependencies: ["Physica"]
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
            name: "Example0",
			dependencies: [
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
				.target(name: "Physica")
				],
			path: "Sources/PhysicaDemo/Example0"
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
