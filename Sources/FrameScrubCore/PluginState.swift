import Foundation

/// The player's state as a plugin page sees it (`framescrub.state`, `framescrub.onstate`): the open file, the
/// position, playback, the loop and the segments. Its JSON always has every key, in a fixed order, with `null` where nothing applies.
public struct PluginState: Equatable, Sendable, Codable {
    /// A file is open; false on the start screen or after a failed open, when the numbers below are zeros.
    public var ready: Bool
    /// The open file's path and name; nil with nothing open.
    public var path: String?
    public var name: String?
    /// The Stash scene's id when the file came from Stash.
    public var scene: String?
    /// The position in seconds and in frames.
    public var t: Double
    public var frame: Int
    public var fps: Double
    /// The length in seconds and in frames.
    public var duration: Double
    public var durationFrames: Int
    public var playing: Bool
    /// The A-B loop, sent as `[a, b]`.
    public var loop: ClosedRange<Double>?
    /// The locked segments; nil with none set.
    public var segments: Segments?
    /// Whether the panel is on screen.
    public var visible: Bool

    /// The segment set as the page sees it: `{list: [[a, b], …], current: i | null, locked, advance}`.
    public struct Segments: Equatable, Sendable, Codable {
        public var list: [ClosedRange<Double>]
        public var current: Int?
        public var locked: Bool
        public var advance: SegmentAdvance

        public init(list: [ClosedRange<Double>], current: Int? = nil, locked: Bool = true, advance: SegmentAdvance = .repeating) {
            self.list = list
            self.current = current
            self.locked = locked
            self.advance = advance
        }

        private enum Key: String, CodingKey { case list, current, locked, advance }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            let pairs = try c.decode([[Double]].self, forKey: .list)
            list = try pairs.map { pair in
                guard pair.count == 2, let segment = LinkTarget.segment(pair[0], pair[1]) else {
                    throw DecodingError.dataCorruptedError(forKey: .list, in: c, debugDescription: "segment is not [a, b]")
                }
                return segment
            }
            current = try c.decodeIfPresent(Int.self, forKey: .current)
            locked = try c.decode(Bool.self, forKey: .locked)
            advance = try c.decode(SegmentAdvance.self, forKey: .advance)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Key.self)
            try c.encode(list.map { [$0.lowerBound, $0.upperBound] }, forKey: .list)
            try c.encode(current, forKey: .current)   // nil as null
            try c.encode(locked, forKey: .locked)
            try c.encode(advance, forKey: .advance)
        }
    }

    public init(ready: Bool = false, path: String? = nil, name: String? = nil, scene: String? = nil, t: Double = 0,
                frame: Int = 0, fps: Double = 0, duration: Double = 0, durationFrames: Int = 0, playing: Bool = false,
                loop: ClosedRange<Double>? = nil, segments: Segments? = nil, visible: Bool = true) {
        self.ready = ready
        self.path = path
        self.name = name
        self.scene = scene
        self.t = t
        self.frame = frame
        self.fps = fps
        self.duration = duration
        self.durationFrames = durationFrames
        self.playing = playing
        self.loop = loop
        self.segments = segments
        self.visible = visible
    }

    private enum Key: String, CodingKey {
        case ready, path, name, scene, t, frame, fps, duration, durationFrames, playing, loop, segments, visible
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        ready = try c.decode(Bool.self, forKey: .ready)
        path = try c.decodeIfPresent(String.self, forKey: .path)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        scene = try c.decodeIfPresent(String.self, forKey: .scene)
        t = try c.decode(Double.self, forKey: .t)
        frame = try c.decode(Int.self, forKey: .frame)
        fps = try c.decode(Double.self, forKey: .fps)
        duration = try c.decode(Double.self, forKey: .duration)
        durationFrames = try c.decode(Int.self, forKey: .durationFrames)
        playing = try c.decode(Bool.self, forKey: .playing)
        if let pair = try c.decodeIfPresent([Double].self, forKey: .loop) {
            guard pair.count == 2, let segment = LinkTarget.segment(pair[0], pair[1]) else {
                throw DecodingError.dataCorruptedError(forKey: .loop, in: c, debugDescription: "loop is not [a, b]")
            }
            loop = segment
        } else {
            loop = nil
        }
        segments = try c.decodeIfPresent(Segments.self, forKey: .segments)
        visible = try c.decode(Bool.self, forKey: .visible)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(ready, forKey: .ready)
        try c.encode(path, forKey: .path)   // an Optional encodes nil as null, not as an absent key
        try c.encode(name, forKey: .name)
        try c.encode(scene, forKey: .scene)
        try c.encode(t, forKey: .t)
        try c.encode(frame, forKey: .frame)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(durationFrames, forKey: .durationFrames)
        try c.encode(playing, forKey: .playing)
        try c.encode(loop.map { [$0.lowerBound, $0.upperBound] }, forKey: .loop)
        try c.encode(segments, forKey: .segments)
        try c.encode(visible, forKey: .visible)
    }

    /// The state as a JSON object with sorted keys; nil only when a number is not finite.
    public var json: String? { PluginJSON.encode(self) }

    public init?(json: String) {
        guard let state = PluginJSON.decode(PluginState.self, from: json) else { return nil }
        self = state
    }
}
