//
//  Example1.swift
//  Physica
//
//  Created by Thiradon Mueangmo on 5/7/2569 BE.
//

import JavaScriptKit
import JavaScriptEventLoop
import Physica

// Animation example
@main
struct Example1 {
	static func main() {
		JavaScriptEventLoop.installGlobalExecutor()
		Task { @MainActor in
			// no font load, then use default fonts
			await boot()
		}
	}
}

@MainActor
func boot() async {
	Storytelling { scene in
		let title = Text("Hello, World!", font: .title)
		scene.add(title)
		scene.play(title.shift( 1.i ).color(.green)) // blend animation
	}
}
