// FacadeRoots — page-lifetime retention for auto-mounted facades. The facade
// spellings are bare statements (`Storytelling { … }`, `Document("…") { … }`),
// so nothing in author code holds the runtime (renderer, rAF loop, listeners,
// article mount) alive; everything the mount produces is parked here instead.

import PhysicaFoundation

#if os(WASI)

@MainActor
public enum FacadeRoots {
    private static var retained: [Any] = []

    /// Keeps `object` alive for the rest of the page's life.
    public static func keep(_ object: Any) {
        retained.append(object)
    }
}

#endif
