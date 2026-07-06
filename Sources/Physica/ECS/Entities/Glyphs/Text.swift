// Text — the facade's text factory: `Text("Hello", font: .title)` resolves the
// role through `FontBook` and returns an ordinary `TextEntity`, so everything
// composes unchanged (`.write()`, `.shift()`, `.color()`, glyph slices, …).
// With no face registered (headless smoke, a failed font fetch) it degrades to
// an empty-glyph entity that keeps the scene graph and timeline shape-stable.

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public func Text(
    _ string: String,
    font role: FontRole = .body,
    color: Color = .white
) -> TextEntity {
    let (font, size) = FontBook.resolve(role)
    if let font {
        return TextEntity(string, font: font, fontSize: size, color: color)
    }
    let entity = TextEntity(glyphs: [], fontSize: size)
    entity.name = string
    return entity
}

@MainActor
public extension TextEntity {
    /// Instance sugar for the static factory: `scene.play(title.write())`.
    func write() -> Animation { .write(self) }
    /// Backward write; the entity leaves the scene when the clip completes.
    func erase() -> Animation { .erase(self) }
}
