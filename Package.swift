// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Physica",
	platforms: [.macOS(.v26)],
	products: [.library(name: "Physica", targets: ["Physica"])],
	dependencies: [.package(url: "https://github.com/swiftwasm/JavaScriptKit.git", branch: "main" )],
    targets: [
		.target(name: "Physica"),
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
