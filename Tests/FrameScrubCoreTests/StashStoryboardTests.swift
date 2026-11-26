import CoreGraphics
import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct StashStoryboardTests {
    @Test func usesCueIntervalsAndLeavesGapsForFallback() throws {
        let index = try #require(StashStoryboard.Index("""
            WEBVTT

            00:00:00.000 --> 00:00:02.500
            scene_sprite.jpg#xywh=0,0,160,90

            cue-2
            00:02.500 --> 00:05.000
            scene_sprite.jpg#xywh=160,0,160,90

            00:06.000 --> 00:08.000
            scene_sprite.jpg#xywh=0,90,160,90
            """))
        #expect(index.rectangle(at: 0) == CGRect(x: 0, y: 0, width: 160, height: 90))
        #expect(index.rectangle(at: 2.499)?.minX == 0)
        #expect(index.rectangle(at: 2.5)?.minX == 160)
        #expect(index.rectangle(at: 5) == nil)
        #expect(index.rectangle(at: 6)?.minY == 90)
        #expect(index.rectangle(at: 8) == nil)
        #expect(index.rectangle(at: .nan) == nil)
    }

    @Test func rejectsInvalidCues() {
        #expect(StashStoryboard.Index("not WEBVTT") == nil)
        #expect(StashStoryboard.Index("""
            WEBVTT

            00:00.000 --> 00:00.500
            scene_sprite.jpg#xywh=-1,0,160,90

            00:61.000 --> 01:02.500
            scene_sprite.jpg#xywh=0,0,160,90
            """) == nil)
    }

    @Test func onlyAllowsAssetsAtTheConfiguredOrigin() throws {
        let base = try #require(URL(string: "https://example.test/stash"))
        let origin = try #require(StashStoryboard.Origin(base))
        #expect(origin.asset("/stash/scene/1/sprite", relativeTo: base)?.absoluteString ==
            "https://example.test/stash/scene/1/sprite")
        #expect(origin.asset("scene/1/sprite", relativeTo: base)?.absoluteString ==
            "https://example.test/stash/scene/1/sprite")
        #expect(origin.asset("https://EXAMPLE.test:443/sprite", relativeTo: base) != nil)
        #expect(origin.asset("http://example.test/sprite", relativeTo: base) == nil)
        #expect(origin.asset("https://example.test:8443/sprite", relativeTo: base) == nil)
        #expect(origin.asset("//other.test/sprite", relativeTo: base) == nil)
        #expect(origin.asset("https://user@example.test/sprite", relativeTo: base) == nil)
    }

    @Test func cropsFromTheTopLeftAndFitsTheRequestedSize() async throws {
        let index = try #require(StashStoryboard.Index("""
            WEBVTT

            00:00.000 --> 00:01.000
            scene_sprite.jpg#xywh=0,0,4,2

            00:01.000 --> 00:02.000
            scene_sprite.jpg#xywh=0,2,4,2

            00:02.000 --> 00:03.000
            scene_sprite.jpg#xywh=0,4,4,2
            """))
        let context = try #require(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 2, width: 4, height: 2))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        let storyboard = StashStoryboard(index: index, sheet: try #require(context.makeImage()))
        let top = try #require(await storyboard.image(at: 0, fitting: 2))
        let bottom = try #require(await storyboard.image(at: 1, fitting: 40))
        #expect(top.width == 2 && top.height == 1)
        #expect(bottom.width == 4 && bottom.height == 2)
        #expect(pixel(in: top) == [0, 255, 0, 255])
        #expect(pixel(in: bottom) == [255, 0, 0, 255])
        #expect(await storyboard.image(at: 2, fitting: 4) == nil)
    }

    private func pixel(in image: CGImage) -> [UInt8] {
        guard let data = image.dataProvider?.data else { return [] }
        return Array((data as Data).prefix(4))
    }
}
