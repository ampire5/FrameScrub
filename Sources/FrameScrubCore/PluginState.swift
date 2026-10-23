import Foundation

/// The player's state as a plugin page sees it (`framescrub.state`, `framescrub.onstate`): the open file, the
/// position, playback and the loop. Its JSON always has every key, in a fixed order, with `null` where nothing applies.
public struct PluginState: Equatable, Sendable, Codable {
    /// The open file's path; nil with nothing open (a Stash scene whose file was not found, the start screen).
    public var path: String?
    /// The Stash scene's id when the file came from Stash.
    public var scene: String?
    /// The position in seconds and in frames.
    public var t: Double
    public var frame: Int
    public var fps: Double
    public var duration: Double
    public var playing: Bool
    /// The A-B loop, sent as `[a, b]`.
    public var loop: ClosedRange<Double>?
    /// Whether the panel is on screen.
    public var visible: Bool

    public init(path: String? = nil, scene: String? = nil, t: Double = 0, frame: Int = 0, fps: Double = 0,
                duration: Double = 0, playing: Bool = false, loop: ClosedRange<Double>? = nil, visible: Bool = true) {
        self.path = path
        self.scene = scene
        self.t = t
        self.frame = frame
        self.fps = fps
        self.duration = duration
        self.playing = playing
        self.loop = loop
        self.visible = visible
    }

    private enum Key: String, CodingKey {
        case path, scene, t, frame, fps, duration, playing, loop, visible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        t = try c.decode(Double.self, forKey: .t)
        frame = try c.decode(Int.self, forKey: .frame)
        fps = try c.decode(Double.self, forKey: .fps)
        duration = try c.decode(Double.self, forKey: .duration)
        playing = try c.decode(Bool.self, forKey: .playing)
        if let pair = try c.decodeIfPresent([Double].self, forKey: .loop) {
            guard pair.count == 2, let segment = LinkTarget.segment(pair[0], pair[1]) else {
                throw DecodingError.dataCorruptedError(forKey: .loop, in: c, debugDescription: "loop is not [a, b]")
            }
            loop = segment
        } else {
            loop = nil
        }
        visible = try c.decode(Bool.self, forKey: .visible)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(path, forKey: .path)   // an Optional encodes nil as null, not as an absent key
        try c.encode(scene, forKey: .scene)
        try c.encode(t, forKey: .t)
        try c.encode(frame, forKey: .frame)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(playing, forKey: .playing)
        try c.encode(loop.map { [$0.lowerBound, $0.upperBound] }, forKey: .loop)
        try c.encode(visible, forKey: .visible)
    }

    /// The state as a JSON object with sorted keys; nil only when a number is not finite.
    public var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    public init?(json: String) {
        guard let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(PluginState.self, from: data)
        else { return nil }
        self = state
    }
}
