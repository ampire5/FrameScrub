import CoreGraphics
import Foundation

/// Decodes single frames for a plugin page's `frame` requests, off the main thread, with its own demuxer and decoder
/// (the player's keep running). One grabber per open file; requests run one after another.
public final class PluginFrameGrabber: @unchecked Sendable {
    public struct Picture: Equatable, Sendable {
        public let frame: Int
        public let pts: Int64
        public let jpeg: Data
        public let size: CGSize
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The file cannot be opened or decoded (the reason as text).
        case decoding(String)
        /// Decoding ended before the frame.
        case noFrame
        /// `stop()` was called.
        case stopped
    }

    private let url: URL
    private let readCache: ReadCache?
    private let rotation: Int
    private let renderer = FrameImageRenderer()
    private let queue = DispatchQueue(label: "framescrub.plugin-frame", qos: .userInitiated)
    private let lock = NSLock()
    private var index: FrameIndex
    private var decoder: VideoDecoder?
    private var stopped = false

    public init(url: URL, index: FrameIndex, rotationClockwise: Int, readCache: ReadCache? = nil) {
        self.url = url
        self.readCache = readCache
        self.index = index
        rotation = rotationClockwise
    }

    /// The exact index arrived: later requests use it.
    public func updateIndex(_ newIndex: FrameIndex) { lock.withLock { index = newIndex } }

    /// No more answers; the decoder goes with the next request's turn.
    public func stop() {
        lock.withLock { stopped = true }
        queue.async { [self] in decoder = nil }
    }

    /// Frame `n` as a JPEG fitted into `maxSide` x `maxSide` pixels; `completion` is called on the main queue.
    public func grab(frame n: Int, maxSide: Int, completion: @escaping @Sendable (Result<Picture, Failure>) -> Void) {
        queue.async { [self] in
            let result = decode(frame: n, maxSide: maxSide)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func decode(frame n: Int, maxSide: Int) -> Result<Picture, Failure> {
        let (current, skip) = lock.withLock { (index, stopped) }
        guard !skip else { return .failure(.stopped) }
        do {
            if decoder == nil {
                decoder = try VideoDecoder(source: MediaSource(url: url, readCache: readCache), index: current)
            }
            let decoder = decoder!
            decoder.index = current
            try decoder.seek(toFrame: n)
            guard let frame = try decoder.nextFrame() else { return .failure(.noFrame) }
            guard let (data, size) = renderer.jpeg(for: frame, rotationClockwise: rotation, maxSide: maxSide) else {
                return .failure(.decoding("cannot encode the picture"))
            }
            return .success(Picture(frame: frame.number, pts: frame.pts, jpeg: data, size: size))
        } catch {
            decoder = nil   // the next request reopens the file
            return .failure(.decoding("\(error)"))
        }
    }
}
