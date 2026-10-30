import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ThumbnailStoreTests {
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func video(_ name: String = "clip.mp4", bytes: Int = 10) throws -> URL {
        let url = makeTemporaryDirectory().appendingPathComponent(name)
        try Data(count: bytes).write(to: url)
        return url
    }

    private func picture(_ width: Int, _ height: Int) -> CIImage {
        CIImage(color: CIColor(red: 0.2, green: 0.6, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    @Test func savesAScaledDownCopyAndReadsItBack() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let url = try video()
        store.save(picture(2560, 1080), for: url, context: context)
        let image = try #require(store.image(for: url))
        #expect(image.width == 1280 && image.height == 540)
    }

    @Test func keepsTheNewest200AtUpTo1280Pixels() {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        #expect(store.limit == 200)
        #expect(store.maxSide == 1280)
    }

    @Test func aSmallPictureIsNotEnlarged() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let url = try video()
        store.save(picture(160, 90), for: url, context: context)
        #expect(store.image(for: url).map { ($0.width, $0.height) } ?? (0, 0) == (160, 90))
    }

    @Test func anotherFileUnderTheSameNameHasNone() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let url = try video(bytes: 10)
        store.save(picture(320, 180), for: url, context: context)
        try Data(count: 11).write(to: url)
        #expect(store.image(for: url) == nil)
    }

    @Test func keepsOnlyTheNewest() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory(), limit: 2)
        let urls = try (0..<3).map { try video("v\($0).mp4") }
        for url in urls { store.save(picture(64, 36), for: url, context: context) }
        #expect(store.image(for: urls[0]) == nil)
        #expect(store.image(for: urls[1]) != nil && store.image(for: urls[2]) != nil)
    }

    @Test func sameSizeOverwriteDropsTheOldPicture() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let url = try video()
        store.save(picture(64, 36), for: url, context: context)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 10)], ofItemAtPath: url.path)
        #expect(!store.has(url) && store.image(for: url) == nil)
    }

    @Test func sourceReplacedDuringDecodeCannotSaveOldPixels() throws {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        let url = try video()
        let identity = try #require(MediaFileIdentity.read(url))
        try Data(count: 10).write(to: url, options: .atomic)
        store.save(picture(64, 36), for: url, context: context, identity: identity)
        #expect(!store.has(url))
    }

    @Test func aMissingVideoHasNone() {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        #expect(store.image(for: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mp4")) == nil)
    }
    @Test func encodingSettingsDoNotReuseOtherPayloads() throws {
        let dir = makeTemporaryDirectory(), url = try video()
        let high = ThumbnailStore(directory: dir, encoding: .standard)
        high.save(picture(64, 36), for: url, context: context)
        let low = ThumbnailStore(directory: dir, encoding: .init(format: .jpeg, quality: 0.5))
        #expect(high.has(url) && !low.has(url))
    }
    @Test func thumbnailDefaultsAreExplicitAndValidated() {
        #expect(ThumbnailEncoding.standard.format == .jpeg && ThumbnailEncoding.standard.quality == 0.8)
        #expect(ThumbnailEncoding(format: .jpeg, quality: .nan).quality == 0.8)
        #expect(ThumbnailEncoding(format: .jpeg, quality: 2).quality == 1)
        #expect(ThumbnailEncoding(format: .jpeg, quality: -1).quality == 0.1)
    }
    @Test func advancedPreferencesUsePercentQualityAndSafeFallback() {
        let name = "thumbnail-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ThumbnailEncoding.configured(defaults) == .standard)
        defaults.set("unsupported", forKey: "thumbnail-format")
        defaults.set(65, forKey: "thumbnail-quality")
        let encoding = ThumbnailEncoding.configured(defaults)
        #expect(encoding.format == .jpeg && encoding.quality == 0.65)
    }
    @Test func runtimeFailureUsesActualJPEGKey() throws {
        let image = try #require(context.createCGImage(picture(32, 18), from: CGRect(x: 0, y: 0, width: 32, height: 18)))
        let requested = ThumbnailEncoding(format: .heic, quality: 0.8)
        let encoded = requested.encode(image) { _, encoding in
            encoding.format == .jpeg ? Data([1]) : nil
        }
        #expect(encoded?.0 == Data([1]) && encoded?.1.cacheKey == "jpeg-q80")
    }
    @Test func optionalEncoderCanReadPersistedJPEGFallbackAfterRelaunch() throws {
        let dir = makeTemporaryDirectory(), url = try video()
        let fallback = ThumbnailStore(directory: dir, encoding: .standard)
        fallback.save(picture(64, 36), for: url, context: context)
        let relaunched = ThumbnailStore(directory: dir, encoding: .init(format: .heic, quality: 0.8))
        #expect(relaunched.has(url) && relaunched.image(for: url) != nil)
    }
}
