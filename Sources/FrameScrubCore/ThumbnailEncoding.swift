import Foundation
import ImageIO

/// Shared thumbnail policy (photo and video bench, docs/bench/2026-10-30-thumbnail-codecs.md). JPEG remains the fast
/// default. Advanced per-app defaults allow a space-saving codec without adding controls to every thumbnail view.
public struct ThumbnailEncoding: Equatable, Sendable {
    public enum Format: String, CaseIterable, Sendable {
        case jpeg, heic, avif
        public var typeIdentifier: String {
            switch self { case .jpeg: "public.jpeg"; case .heic: "public.heic"; case .avif: "public.avif" }
        }
    }
    public let format: Format
    public let quality: Double
    public static let standard = ThumbnailEncoding(format: .jpeg, quality: 0.8)
    public init(format: Format, quality: Double) {
        let encoders = CGImageDestinationCopyTypeIdentifiers() as! [String]
        self.format = encoders.contains(format.typeIdentifier) ? format : .jpeg
        self.quality = quality.isFinite ? (min(1, max(0.1, quality)) * 100).rounded() / 100 : 0.8
    }
    /// Optional advanced settings, applied on the next launch: thumbnail-format=jpeg|heic|avif and
    /// thumbnail-quality=10…100 in this application's UserDefaults domain. Old payloads remain disposable.
    public static func configured(_ defaults: UserDefaults = .standard) -> Self {
        let format = defaults.string(forKey: "thumbnail-format").flatMap(Format.init(rawValue:)) ?? .jpeg
        let quality = defaults.object(forKey: "thumbnail-quality") == nil ? 80 : defaults.double(forKey: "thumbnail-quality")
        return Self(format: format, quality: quality / 100)
    }
    public var cacheKey: String { "\(format.rawValue)-q\(Int((quality * 100).rounded()))" }
    /// A failed optional encoder degrades to JPEG at the same quality. Return the actual encoding for the cache key.
    func encode(_ image: CGImage, using encoder: (CGImage, Self) -> Data?) -> (Data, Self)? {
        if let bytes = encoder(image, self) { return (bytes, self) }
        guard format != .jpeg else { return nil }
        let fallback = Self(format: .jpeg, quality: quality)
        return encoder(image, fallback).map { ($0, fallback) }
    }
}
