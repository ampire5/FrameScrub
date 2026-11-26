import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Versioned JPEG payloads in the media catalog, keyed by the source's full identity and picture variant.
/// Encoding, stat, SQLite and decoding run on the caller's existing background picture queues.
public final class ThumbnailStore: @unchecked Sendable {
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/thumbnails")
    public static func configuredSide(poster: Bool, defaults: UserDefaults = .standard) -> CGFloat {
        let key = poster ? "thumbnail-poster-size" : "thumbnail-recent-size"
        guard defaults.object(forKey: key) != nil else { return poster ? 480 : 1280 }
        return CGFloat(min(1920, max(128, defaults.integer(forKey: key))))
    }
    public let directory: URL
    public let limit: Int
    public let maxSide: CGFloat
    private let catalog: MediaCatalog
    private let encoding: ThumbnailEncoding
    private let encodingLock = NSLock()
    private let writeLock = NSLock()
    private var runtimeFallback = false
    public init(directory: URL = ThumbnailStore.defaultDirectory, limit: Int = 200, maxSide: CGFloat = ThumbnailStore.configuredSide(poster: false),
                encoding: ThumbnailEncoding = .configured()) {
        self.directory = directory; self.limit = limit; self.maxSide = maxSide
        self.encoding = encoding
        let isStandard = directory == Self.defaultDirectory || directory == Self.defaultDirectory.appendingPathComponent("posters")
        catalog = isStandard ? .shared : MediaCatalog(url: directory.appendingPathComponent("catalog.sqlite"))
    }

    /// `picture` is the frame as shown (upright, cropped, square pixels). Failures are ignored: thumbnails are a convenience.
    @discardableResult
    public func save(_ picture: CIImage, for video: URL, context: CIContext, identity expected: MediaFileIdentity? = nil,
                     onlyIfMissing: Bool = false) -> CGImage? {
        guard let identity = expected ?? MediaFileIdentity.read(video), picture.extent.width >= 1, picture.extent.height >= 1 else { return nil }
        let size = picture.extent.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let origin = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        let scaled = scale < 1 ? ImageScaling.lanczos(origin, to: target) : origin
        guard let image = context.createCGImage(scaled, from: CGRect(origin: .zero, size: target),
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return nil }
        let requested = activeEncoding
        guard let (bytes, actual) = requested.encode(image, using: Self.encodeImage) else { return nil }
        if actual.format != requested.format { encodingLock.withLock { runtimeFallback = true } }
        // Recent's generator and playback writer share this store. An in-flight generated fallback fills a
        // missing card without replacing a playback frame that finished while the generator was decoding.
        return writeLock.withLock {
            if onlyIfMissing, self.image(for: identity) != nil { return nil }
            do {
                let preferred = variant(encoding)
                // If a newer picture was stored in the fallback format, retire the preferred entry it replaces.
                try catalog.putImage(bytes, identity: identity, variant: variant(actual), limit: limit,
                                     replacingVariant: preferred)
                return image
            } catch { return nil }
        }
    }

    private var activeEncoding: ThumbnailEncoding {
        encodingLock.withLock { runtimeFallback ? .init(format: .jpeg, quality: encoding.quality) : encoding }
    }
    private func variant(_ encoding: ThumbnailEncoding) -> String {
        "\(directory.lastPathComponent)-\(Int(maxSide))-v3-\(encoding.cacheKey)"
    }
    private static func encodeImage(_ image: CGImage, encoding: ThumbnailEncoding) -> Data? {
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, encoding.format.typeIdentifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: encoding.quality] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? bytes as Data : nil
    }

    /// Check the requested encoding first, then its compatible JPEG fallback. The fallback remains visible after
    /// relaunch. A successful fallback save removes any older preferred picture of that same file identity.
    private var readableVariants: [String] {
        let preferred = variant(encoding)
        guard encoding.format != .jpeg else { return [preferred] }
        return [preferred, variant(.init(format: .jpeg, quality: encoding.quality))]
    }
    public func has(_ video: URL) -> Bool {
        guard let identity = MediaFileIdentity.read(video) else { return false }
        return readableVariants.contains { (try? catalog.hasImage(identity, variant: $0)) ?? false }
    }

    /// A folder-card preview may display cached posters before the browser can list its videos.
    public func cachedFolderCover(in folder: URL) -> [CGImage] {
        let variants = readableVariants
        let preferred = variants[0]
        let payloads = try? catalog.folderCoverImages(in: folder, preferred: preferred, fallback: variants.last ?? preferred,
                                                      limit: HomeFolders.coverVideoLimit)
        return payloads?.compactMap(Self.decodeImage) ?? []
    }

    private static func decodeImage(_ bytes: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    public func image(for video: URL) -> CGImage? {
        guard let identity = MediaFileIdentity.read(video) else { return nil }
        return image(for: identity)
    }

    private func image(for identity: MediaFileIdentity) -> CGImage? {
        for variant in readableVariants {
            guard let bytes = try? catalog.image(identity, variant: variant),
                  let image = Self.decodeImage(bytes) else { continue }
            return image
        }
        return nil
    }
}
