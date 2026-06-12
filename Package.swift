// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Physica",
	platforms: [.macOS(.v26)],
	products: [.library(name: "Physica", targets: ["Physica"])],
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
        .executableTarget(
            name: "PhysicsEngine",
			dependencies: [
				.product(name: "JavaScriptKit", package: "JavaScriptKit"),
				.product(name: "JavaScriptEventLoop", package: "JavaScriptKit"),
				.target(name: "Physica")
				],
			plugins: [
				.plugin(name: "BridgeJS", package: "JavaScriptKit")
			]
        ),
        .testTarget(
            name: "PhysicaTests",
            dependencies: ["Physica"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
