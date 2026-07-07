// FontBook — the role → (face, size) registry behind `Text(_:font:)`. The web
// facade fills it once at mount (after the async font fetches), and authoring
// code reads it synchronously while scenes build. Roles without a registered
// face fall back to `fallback`; roles without a registered size use the
// built-in scale below, so `Text("…", font: .title)` reads sensibly with a
// single loaded face.

import PhysicaFoundation
import PhysicaTypesetting

@MainActor
public enum FontBook {
    struct Entry {
        var font: Font
        var size: Real
    }

    private static var entries: [FontRole: Entry] = [:]

    /// The face used for any role without its own registration (typically the
    /// default body face the facade loads first).
    public static var fallback: Font?

    /// Registers `font` for `role`; `size` overrides the role's built-in scale.
    public static func register(_ font: Font, for role: FontRole, size: Real? = nil) {
        entries[role] = Entry(font: font, size: size ?? defaultSize(for: role))
    }

    /// Resolves a role: its registered face (else `fallback`, else nil) and its
    /// effective size. A nil face degrades `Text()` to an empty-glyph entity.
    public static func resolve(_ role: FontRole) -> (font: Font?, size: Real) {
        if let entry = entries[role] { return (entry.font, entry.size) }
        return (fallback, defaultSize(for: role))
    }

    /// Whether `role` has its own registration (the facade skips fetching a
    /// default face for roles the author already filled via `Config`).
    public static func hasRegistration(for role: FontRole) -> Bool {
        entries[role] != nil
    }

    /// Built-in size scale (world units at the default fit-10 camera).
    public static func defaultSize(for role: FontRole) -> Real {
        switch role {
        case .title: return 1.2
        case .heading: return 0.8
        case .body: return 0.5
        case .caption: return 0.35
        case .math: return 0.6
        case .mono: return 0.45
        }
    }

    /// Clears every registration (tests; a fresh editor session).
    public static func reset() {
        entries = [:]
        fallback = nil
    }
}

public extension Font {
    /// The face a bare `TextEntity("Hi")` renders with: the registered default
    /// (`Config.defaultFont` — the facade fills it at mount), else `.empty`
    /// (text degrades to an empty-glyph entity, never traps).
    @MainActor static var `default`: Font { FontBook.fallback ?? .empty }
}
