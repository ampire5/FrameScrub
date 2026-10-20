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
        for (i, url) in urls.enumerated() {
            store.save(picture(64, 36), for: url, context: context)
            let file = try #require(store.fileURL(for: url))
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: Double(i - 10))], ofItemAtPath: file.path)
        }
        store.save(picture(64, 36), for: urls[2], context: context)   // prunes after the dates were set
        #expect(store.image(for: urls[0]) == nil)
        #expect(store.image(for: urls[1]) != nil && store.image(for: urls[2]) != nil)
    }

    @Test func aMissingVideoHasNone() {
        let store = ThumbnailStore(directory: makeTemporaryDirectory())
        #expect(store.image(for: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString).mp4")) == nil)
    }
}
