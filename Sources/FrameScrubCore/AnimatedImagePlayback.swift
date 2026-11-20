import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A GIF or animated WebP cursor. Create and use it on one background worker.
public final class AnimatedImagePlayback {
    public struct Frame: Sendable {
        public let image: CGImage
        public let index: Int
        public let seconds: Double
        public let duration: Double
    }

    public enum DecodingError: Error, Equatable {
        case unsupportedImage
        case invalidAnimation
        case encodedSizeLimit
        case canvasSizeLimit
        case invalidFrameIndex(Int)
        case frameUnavailable(Int)
    }

    /// Total plays including the initial play. Nil means the animation repeats indefinitely.
    public let totalPlayCount: Int?
    public var frameCount: Int { frameEndMilliseconds.count }
    public var duration: Double { Double(frameEndMilliseconds.last ?? 0) / 1_000 }
    public private(set) var currentFrame: Frame?

    // On arm64 macOS 27.2.1, Image I/O requested all 70.8 MB of a 40-frame
    // 768 × 768 WebP at open, then retained about 91 MB more after rendering it.
    // Bound compressed storage, canvas allocations and the timing metadata separately.
    public static let maximumEncodedBytes = 64 * 1024 * 1024
    public static let maximumCanvasPixels = 3840 * 2160
    private static let maximumFrameCount = 30_000

    // A 131-frame 768 × 768 WebP with partial frames rendered in 0.27–0.28 s per
    // round with this window (101 MB peak RSS), compared with 1.60–1.63 s for
    // a fresh source per frame (98 MB peak RSS) on arm64 macOS 27.2.1.
    private static let decodeWindowBytes = 32 * 1024 * 1024
    private static let maximumWindowRequests = 16
    private let encoded: CFData
    private let decodeBatchCapacity: Int
    private var decodeSource: CGImageSource?
    private var decodeCount = 0
    private let frameEndMilliseconds: [Int64]
    private let isCancelled: () -> Bool

    public convenience init(url: URL) throws {
        try self.init(source: FileByteSource(url: url))
    }

    /// The source may own a read-only descriptor received from another process.
    /// Read the bounded compressed data once and load only timing metadata at open.
    public init(source: ByteSource, isCancelled: @escaping () -> Bool = { false }) throws {
        self.isCancelled = isCancelled
        if isCancelled() { throw CancellationError() }
        guard source.size > 0 else { throw DecodingError.unsupportedImage }
        guard source.size <= Self.maximumEncodedBytes else { throw DecodingError.encodedSizeLimit }
        var bytes = Data(count: Int(source.size))
        try bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { throw DecodingError.invalidAnimation }
            var offset = 0
            while offset < buffer.count {
                if isCancelled() { throw CancellationError() }
                let count = min(1024 * 1024, buffer.count - offset)
                let read = try source.read(at: Int64(offset), count: count, into: base + offset)
                guard read > 0, read <= count else { throw DecodingError.invalidAnimation }
                offset += read
            }
        }
        if isCancelled() { throw CancellationError() }
        let encoded = bytes as CFData
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithData(encoded, options),
              let type = CGImageSourceGetType(imageSource) as String? else {
            throw DecodingError.unsupportedImage
        }

        let keys: (dictionary: CFString, frames: CFString, loopCount: CFString, width: CFString, height: CFString,
                   unclampedDelay: CFString, delay: CFString)
        switch type {
        case UTType.gif.identifier:
            keys = (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFFrameInfoArray,
                    kCGImagePropertyGIFLoopCount, kCGImagePropertyGIFCanvasPixelWidth,
                    kCGImagePropertyGIFCanvasPixelHeight, kCGImagePropertyGIFUnclampedDelayTime,
                    kCGImagePropertyGIFDelayTime)
        case UTType.webP.identifier:
            keys = (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPFrameInfoArray,
                    kCGImagePropertyWebPLoopCount, kCGImagePropertyWebPCanvasPixelWidth,
                    kCGImagePropertyWebPCanvasPixelHeight, kCGImagePropertyWebPUnclampedDelayTime,
                    kCGImagePropertyWebPDelayTime)
        default:
            throw DecodingError.unsupportedImage
        }

        let count = CGImageSourceGetCount(imageSource)
        guard count > 1 else { throw DecodingError.unsupportedImage }
        guard count <= Self.maximumFrameCount else { throw DecodingError.invalidAnimation }
        guard let properties = CGImageSourceCopyProperties(imageSource, nil) as? [String: Any],
              let animation = properties[keys.dictionary as String] as? [String: Any],
              let width = animation[keys.width as String] as? Int, width > 0,
              let height = animation[keys.height as String] as? Int, height > 0,
              let frames = animation[keys.frames as String] as? [[String: Any]],
              frames.count == count else {
            throw DecodingError.invalidAnimation
        }

        guard width <= Self.maximumCanvasPixels / height else { throw DecodingError.canvasSizeLimit }

        // GIF units are centiseconds, WebP units are milliseconds. Accumulate the exact
        // integer durations so a seek to a frame boundary can select the new frame.
        var endMilliseconds: Int64 = 0
        var frameEnds: [Int64] = []
        frameEnds.reserveCapacity(count)
        for frame in frames {
            if isCancelled() { throw CancellationError() }
            let unclamped = frame[keys.unclampedDelay as String] as? Double ?? 0
            // A zero/missing delay uses Image I/O's display delay, so playback still advances.
            let delay = unclamped > 0 ? unclamped : (frame[keys.delay as String] as? Double ?? 0.1)
            guard let milliseconds = Int64(exactly: (delay * 1_000).rounded()), milliseconds > 0 else {
                throw DecodingError.invalidAnimation
            }
            let (end, overflow) = endMilliseconds.addingReportingOverflow(milliseconds)
            guard !overflow else { throw DecodingError.invalidAnimation }
            endMilliseconds = end
            frameEnds.append(end)
        }

        self.encoded = encoded
        decodeBatchCapacity = max(1, min(Self.maximumWindowRequests, Self.decodeWindowBytes / (width * height * 4)))
        decodeSource = imageSource
        frameEndMilliseconds = frameEnds
        // Image I/O normalizes the GIF extension's repeat count to total plays.
        // WebP already stores a total play count. Both report zero for indefinite playback.
        let plays = animation[keys.loopCount as String] as? Int ?? 1
        totalPlayCount = plays == 0 ? nil : max(1, plays)
    }

    /// The Netscape loop extension normally precedes the first image. Read only a bounded prefix for it.
    /// Zero stands for unbounded repetition, as in the playback provider.
    public static func gifPlayCount(in source: ByteSource) throws -> Int {
        var header = [UInt8](repeating: 0, count: Int(min(source.size, 64 * 1024)))
        guard header.count >= 13 else { return 1 }
        let length = try header.withUnsafeMutableBytes {
            try source.read(at: 0, count: $0.count, into: $0.baseAddress!)
        }
        let packed = header[10]
        var cursor = 13 + (packed & 0x80 == 0 ? 0 : 3 * (2 << Int(packed & 7)))
        while cursor + 2 < length, header[cursor] == 0x21 {
            let kind = header[cursor + 1]
            cursor += 2
            if kind == 0xff, cursor + 16 < length, header[cursor] == 11,
               header[(cursor + 1)..<(cursor + 12)].elementsEqual("NETSCAPE2.0".utf8),
               header[cursor + 12] == 3, header[cursor + 13] == 1 {
                let repeats = Int(header[cursor + 14]) | Int(header[cursor + 15]) << 8
                return repeats == 0 ? 0 : repeats + 1
            }
            while cursor < length {
                let block = Int(header[cursor])
                cursor += 1 + block
                if block == 0 { break }
            }
        }
        return 1
    }

    /// Before the first display, next presents the first frame. At the end it leaves the cursor in place.
    public func next() throws -> Frame? {
        let index = (currentFrame?.index ?? -1) + 1
        guard index < frameCount else { return nil }
        return try frame(at: index)
    }

    public func previous() throws -> Frame? {
        guard let currentFrame, currentFrame.index > 0 else { return nil }
        return try frame(at: currentFrame.index - 1)
    }

    /// Positions within a frame select that frame. A seek to the duration holds the last frame.
    public func seek(to seconds: Double) throws -> Frame {
        let position = seconds.isNaN ? 0 : seconds
        var first = 0
        var last = frameCount - 1
        while first < last {
            let middle = first + (last - first) / 2
            if position < Double(frameEndMilliseconds[middle]) / 1_000 {
                last = middle
            } else {
                first = middle + 1
            }
        }
        return try frame(at: first)
    }

    @discardableResult
    public func frame(at index: Int) throws -> Frame {
        if isCancelled() { throw CancellationError() }
        guard frameEndMilliseconds.indices.contains(index) else { throw DecodingError.invalidFrameIndex(index) }
        if let currentFrame, currentFrame.index == index { return currentFrame }

        // Image I/O can retain decoded frames in the source. Reset it before its estimated
        // canvas cache exceeds the batch budget, and detach each returned worker-rendered image.
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        if decodeSource == nil || decodeCount == decodeBatchCapacity {
            decodeSource = nil
            decodeSource = CGImageSourceCreateWithData(encoded, options)
            decodeCount = 0
        }
        decodeCount += 1
        let image = try autoreleasepool {
            guard let source = decodeSource,
                  let composite = CGImageSourceCreateImageAtIndex(source, index, options),
                  CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                  composite.width > 0, composite.height > 0,
                  composite.width <= Self.maximumCanvasPixels / composite.height,
                  let space = composite.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                      data: nil, width: composite.width, height: composite.height, bitsPerComponent: 8,
                      bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                throw DecodingError.frameUnavailable(index)
            }
            context.draw(composite, in: CGRect(x: 0, y: 0, width: composite.width, height: composite.height))
            guard let image = context.makeImage() else { throw DecodingError.frameUnavailable(index) }
            return image
        }
        if isCancelled() { throw CancellationError() }
        let start = index == 0 ? 0 : frameEndMilliseconds[index - 1]
        let frame = Frame(image: image, index: index, seconds: Double(start) / 1_000,
                          duration: Double(frameEndMilliseconds[index] - start) / 1_000)
        currentFrame = frame
        return frame
    }
}
