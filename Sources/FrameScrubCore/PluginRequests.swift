import CoreGraphics
import Foundation

/// The answer to `request("info")`: the open file's media details.
public struct PluginInfo: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var fps: Double
    /// The length in seconds and in frames.
    public var duration: Double
    public var durationFrames: Int
    /// The coded picture size and the rotation (clockwise degrees) the player applies to it.
    public var width: Int
    public var height: Int
    public var rotation: Int
    /// The video codec's name as the demuxer reports it ("h264", "hevc").
    public var codec: String?
    /// Whether the file is read from disk or from a stream, Stash's or a page's (then `path` is the stream's URL too).
    public var source: PluginSource
    /// The stream's URL; null for a file.
    public var url: String?

    public init(path: String, name: String, fps: Double, duration: Double, durationFrames: Int, width: Int, height: Int,
                rotation: Int, codec: String?, source: PluginSource = .file, url: String? = nil) {
        self.path = path
        self.name = name
        self.fps = fps
        self.duration = duration
        self.durationFrames = durationFrames
        self.width = width
        self.height = height
        self.rotation = rotation
        self.codec = codec
        self.source = source
        self.url = url
    }

    enum CodingKeys: String, CodingKey {
        case path, name, fps, duration, durationFrames, width, height, rotation, codec, source, url
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encode(name, forKey: .name)
        try c.encode(fps, forKey: .fps)
        try c.encode(duration, forKey: .duration)
        try c.encode(durationFrames, forKey: .durationFrames)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotation, forKey: .rotation)
        try c.encodeIfPresent(codec, forKey: .codec)
        try c.encode(source, forKey: .source)
        try c.encode(url, forKey: .url)   // nil as null, not an absent key
    }

    public var json: String? { PluginJSON.encode(self) }
}

/// The answer to `request("marks")`: the A-B range and the cut marks, each in seconds and in frames.
public struct PluginMarks: Codable, Equatable, Sendable {
    public struct Segment: Codable, Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var startFrame: Int
        public var endFrame: Int

        public init(start: Double, end: Double, startFrame: Int, endFrame: Int) {
            self.start = start
            self.end = end
            self.startFrame = startFrame
            self.endFrame = endFrame
        }
    }

    /// The A-B range as `[a, b]` seconds, null without one.
    public var loop: [Double]?
    /// The A-B range in frames, null without one.
    public var loopFrames: [Int]?
    public var segments: [Segment]
    /// An open mark (in, no out yet): its frame and second; null without one.
    public var openFrame: Int?
    public var openStart: Double?

    public init(loop: ClosedRange<Double>?, loopFrames: ClosedRange<Int>?, segments: [Segment], openFrame: Int?,
                openStart: Double?) {
        self.loop = loop.map { [$0.lowerBound, $0.upperBound] }
        self.loopFrames = loopFrames.map { [$0.lowerBound, $0.upperBound] }
        self.segments = segments
        self.openFrame = openFrame
        self.openStart = openStart
    }

    /// From the player's marks; `seconds` is the index's frame-to-time mapping.
    public init(marks: CutMarks, loopA: Int?, loopB: Int?, seconds: (Int) -> Double) {
        let loopFrames: ClosedRange<Int>? = if let loopA, let loopB, loopB >= loopA { loopA...loopB } else { nil }
        self.init(loop: loopFrames.map { seconds($0.lowerBound)...seconds($0.upperBound) }, loopFrames: loopFrames,
                  segments: marks.segments.map {
                      Segment(start: seconds($0.start), end: seconds($0.end), startFrame: $0.start, endFrame: $0.end)
                  },
                  openFrame: marks.open, openStart: marks.open.map(seconds))
    }

    private enum Key: String, CodingKey { case loop, loopFrames, segments, openFrame, openStart }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(loop, forKey: .loop)   // nil as null, not an absent key
        try c.encode(loopFrames, forKey: .loopFrames)
        try c.encode(segments, forKey: .segments)
        try c.encode(openFrame, forKey: .openFrame)
        try c.encode(openStart, forKey: .openStart)
    }

    public var json: String? { PluginJSON.encode(self) }
}

/// The answer to `request("playlist")`: the file's place in its folder.
public struct PluginPlaylist: Codable, Equatable, Sendable {
    /// Zero-based, among the files the folder's filter lets through.
    public var index: Int
    public var count: Int
    /// The folder's videos before the filter.
    public var total: Int
    public var name: String
    /// What the playlist is: the open file's folder, a list a page gave, or the Stash queue.
    public var source: Source

    public enum Source: String, Codable, Sendable {
        case folder, list, stash
    }

    public init(index: Int, count: Int, total: Int, name: String, source: Source = .folder) {
        self.index = index
        self.count = count
        self.total = total
        self.name = name
        self.source = source
    }

    public var json: String? { PluginJSON.encode(self) }
}

/// `request("frame", {t | frame, maxSize?})`: a picture of one frame, fitted into `maxSize` x `maxSize` pixels.
public struct PluginFrameRequest: Equatable, Sendable {
    public enum Position: Equatable, Sendable {
        case seconds(Double)
        case frame(Int)
    }

    /// The largest picture the page may ask for; a larger `maxSize` is brought down to it.
    public static let largestSize = 512
    public static let smallestSize = 16

    public var position: Position
    public var maxSize: Int

    public init(position: Position, maxSize: Int = PluginFrameRequest.largestSize) {
        self.position = position
        self.maxSize = maxSize
    }

    init(_ args: Arguments) throws(PluginMessage.Failure) {
        switch (args.has("t"), args.has("frame")) {
        case (true, true): throw PluginMessage.Failure("t or frame, not both")
        case (false, false): throw PluginMessage.Failure("t or frame is missing")
        case (true, false): position = .seconds(try args.time("t"))
        case (false, true):
            let n = try args.number("frame")
            guard n >= 0, n < Double(Int32.max) else { throw PluginMessage.Failure("frame is out of range") }
            position = .frame(Int(n))
        }
        if let size = try args.optionalNumber("maxSize") {
            guard size >= Double(Self.smallestSize) else { throw PluginMessage.Failure("maxSize must be at least \(Self.smallestSize)") }
            maxSize = Int(min(size, Double(Self.largestSize)))
        } else {
            maxSize = Self.largestSize
        }
    }

    /// The frame number for a file of `frameCount` frames; nil when the position is past its end.
    public func frameNumber(frameCount: Int, frameForSeconds: (Double) -> Int) -> Int? {
        let n: Int
        switch position {
        case let .frame(frame): n = frame
        case let .seconds(seconds): n = frameForSeconds(seconds)
        }
        return (0..<frameCount).contains(n) ? n : nil
    }
}

/// The answer to `request("frame")`: the frame as a JPEG data URL.
public struct PluginFrame: Codable, Equatable, Sendable {
    public var t: Double
    public var frame: Int
    public var width: Int
    public var height: Int
    public var dataURL: String

    public init(t: Double, frame: Int, width: Int, height: Int, jpeg: Data) {
        self.t = t
        self.frame = frame
        self.width = width
        self.height = height
        dataURL = "data:image/jpeg;base64," + jpeg.base64EncodedString()
    }

    public var json: String? { PluginJSON.encode(self) }
}
