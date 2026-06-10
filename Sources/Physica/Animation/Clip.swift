// AnimationClip — one scheduled step of the scene script, made of parallel tracks.

@MainActor
public final class AnimationClip: Identifiable {
    public let label: String
    public private(set) var tracks: [any AnimationTrackProtocol]
    private let explicitDuration: TimeInterval?

    /// Longest track (offset + duration), or the explicit duration for waits.
    public var duration: TimeInterval {
        explicitDuration ?? tracks.map { $0.offset + $0.duration }.max() ?? 0
    }

    public private(set) var hasBegun = false

    init(label: String, tracks: [any AnimationTrackProtocol], explicitDuration: TimeInterval? = nil) {
        self.label = label
        self.tracks = tracks
        self.explicitDuration = explicitDuration
    }

    func begin(in scene: Scene) {
        hasBegun = true
        for track in tracks {
            track.begin(in: scene)
        }
    }

    func apply(at clipTime: TimeInterval, in scene: Scene) {
        let t = min(max(clipTime, 0), duration)
        for track in tracks {
            track.apply(at: t, in: scene)
        }
    }

    func rewind(in scene: Scene) {
        for track in tracks.reversed() {
            track.rewind(in: scene)
        }
    }

    public var debugString: String {
        let trackLines = tracks.map { "    \($0.label) [\(fmt($0.offset, decimals: 2))s + \(fmt($0.duration, decimals: 2))s]" }
        return "clip '\(label)' \(fmt(duration, decimals: 2))s\n" + trackLines.joined(separator: "\n")
    }
}
