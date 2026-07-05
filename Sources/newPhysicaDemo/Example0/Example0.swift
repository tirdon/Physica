//
//  Example0.swift
//  Physica
//
//  Created by Thiradon Mueangmo on 5/7/2569 BE.
//

import JavaScriptKit
import JavaScriptEventLoop
import Physica

// Interactive presentation slide example
@main
struct Example0 {
	static func main() {
		JavaScriptEventLoop.installGlobalExecutor()
		Task { @MainActor in
			// no font load, then use default fonts
			Storytelling { // auto render in init()
				Slide(onAppear: nil, onDisappear: .fadeOut) { scene in
					let title = Text("Hello, World!", font: .title)
					
					scene.play(title.write())
				}
				
				Slide("slide 2's name") { scene in
					
				}
				
				Slide { scene in
					
				}
			}
		}
	}
}
