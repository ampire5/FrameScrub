import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A JPEG of the last picture seen in each file (longest side at most `maxSide` pixels), for the start screen. Keyed
/// like `ResumeStore` (path and size), so a different file saved under the same name has none; only the `limit`
/// newest are kept. Pictures saved smaller by an older version stay as they are until the file is left again.
public final class ThumbnailStore: @unchecked Sendable {   // only constants: each call reads or writes its own file
    public static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FrameScrub/thumbnails")

    public let directory: URL
    public let limit: Int
    public let maxSide: CGFloat

    public init(directory: URL = ThumbnailStore.defaultDirectory, limit: Int = 200, maxSide: CGFloat = 1280) {
        self.directory = directory
        self.limit = limit
        self.maxSide = maxSide
    }

    /// Part of each file name: raising it drops every saved picture (2: mirrored display matrices are read upright).
    static let version = 2

    func fileURL(for video: URL) -> URL? {
        guard let key = ResumeStore.key(for: video) else { return nil }
        let hash = SHA256.hash(data: Data("\(key)\n\(Self.version)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".jpg")
    }

    /// `picture` is the frame as shown (upright, cropped, square pixels). Failures are ignored: thumbnails are a convenience.
    public func save(_ picture: CIImage, for video: URL, context: CIContext) {
        guard let file = fileURL(for: video), picture.extent.width >= 1, picture.extent.height >= 1 else { return }
        let size = picture.extent.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
        let origin = picture.transformed(by: CGAffineTransform(translationX: -picture.extent.minX, y: -picture.extent.minY))
        let scaled = scale < 1 ? ImageScaling.lanczos(origin, to: target) : origin
        guard let image = context.createCGImage(scaled, from: CGRect(origin: .zero, size: target),
                                                format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Written beside it and moved over it: the start screen may read it meanwhile (saves run in the background).
        let partial = file.appendingPathExtension("partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination), rename(partial.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: partial)
            return
        }
        prune()
    }

    public func image(for video: URL) -> CGImage? {
        guard let file = fileURL(for: video), let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func prune() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter({ $0.pathExtension == "jpg" }), files.count > limit else { return }
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: keys))?.contentModificationDate ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(files.count - limit) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
