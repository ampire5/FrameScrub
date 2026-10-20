import CoreImage
import Foundation
import Testing
@testable import FrameScrubCore

/// A grey picture of `size` with black bars: `rect` (pixels, y up) is the lit part.
private func letterboxed(_ size: CGSize, picture rect: CGRect, level: CGFloat = 0.6) -> CIImage {
    let black = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size))
    return CIImage(color: CIColor(red: level, green: level, blue: level)).cropped(to: rect).composited(over: black)
}

private func approximately(_ a: CGRect?, _ b: CGRect, tolerance: CGFloat = 0.0005) -> Bool {
    guard let a else { return false }
    return abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
        && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
}

private let context = CIContext(options: [.cacheIntermediates: false])
private let full = CGRect(x: 0, y: 0, width: 1, height: 1)

@Suite struct AspectModeTests {
    @Test func aCyclesThroughEveryModeBackToAuto() {
        var mode = AspectMode.auto
        var seen: [AspectMode] = []
        repeat { seen.append(mode); mode = mode.next } while mode != .auto
        #expect(seen == [.auto, .noCrop, .ratio16x9, .ratio4x3, .ratio235, .squarePixels])
    }
}

@Suite struct DisplayGeometryTests {
    private let pal = CGSize(width: 720, height: 576)
    private let sar = 64.0 / 45

    @Test func autoUsesTheFileAspectAndTheDetectedCrop() {
        let crop = CGRect(x: 0, y: 88.0 / 576, width: 1, height: 400.0 / 576)
        let geometry = DisplayGeometry.resolve(mode: .auto, upright: pal, rotationClockwise: 0, sampleAspect: sar, detectedCrop: crop)
        #expect(geometry.cropRect(in: pal) == CGRect(x: 0, y: 88, width: 720, height: 400))
        #expect(geometry.displaySize(of: pal) == CGSize(width: 1024, height: 400))   // stretched, not squeezed
        #expect(abs(geometry.aspect(of: pal) - 2.56) < 0.001)
    }

    @Test func noCropKeepsTheBarsButNotTheSquarePixels() {
        let geometry = DisplayGeometry.resolve(mode: .noCrop, upright: pal, rotationClockwise: 0, sampleAspect: sar,
                                               detectedCrop: CGRect(x: 0, y: 0.2, width: 1, height: 0.6))
        #expect(geometry.displaySize(of: pal) == CGSize(width: 1024, height: 576))
    }

    @Test func aForcedRatioStretchesTheWholePicture() {
        let hd = CGSize(width: 1920, height: 1080)
        let fourThree = DisplayGeometry.resolve(mode: .ratio4x3, upright: hd, rotationClockwise: 0, sampleAspect: 1,
                                                detectedCrop: CGRect(x: 0, y: 0.1, width: 1, height: 0.8))
        #expect(fourThree.crop == full)
        #expect(fourThree.displaySize(of: hd) == CGSize(width: 1920, height: 1440))   // narrower: taller, not thinner
        let wide = DisplayGeometry.resolve(mode: .ratio235, upright: hd, rotationClockwise: 0, sampleAspect: 1, detectedCrop: nil)
        #expect(abs(wide.aspect(of: hd) - 2.35) < 0.001)
    }

    @Test func squarePixelsIgnoresTheFile() {
        let geometry = DisplayGeometry.resolve(mode: .squarePixels, upright: pal, rotationClockwise: 0, sampleAspect: sar,
                                               detectedCrop: CGRect(x: 0, y: 0.2, width: 1, height: 0.6))
        #expect(geometry == .identity)
    }

    @Test func aSidewaysVideoTurnsItsSampleAspect() {
        let upright = CGSize(width: 576, height: 720)
        let geometry = DisplayGeometry.resolve(mode: .auto, upright: upright, rotationClockwise: 90, sampleAspect: sar, detectedCrop: nil)
        #expect(geometry.displaySize(of: upright) == CGSize(width: 576, height: 1024))
    }

    @Test func appliedCropsAndStretches() {
        let picture = CGRect(x: 0, y: 88, width: 720, height: 400)
        let geometry = DisplayGeometry(crop: CGRect(x: 0, y: 88.0 / 576, width: 1, height: 400.0 / 576), pixelAspect: sar)
        let image = geometry.applied(to: letterboxed(pal, picture: picture))
        #expect(image.extent == CGRect(x: 0, y: 0, width: 1024, height: 400))
        #expect(BlackBars.contentRect(of: image, context: context).map { approximately($0, full) } == true)   // no bars left
    }
}

@Suite struct AspectThumbnailTests {
    @Test func aThumbnailIsCutAndStretchedLikeTheScreenAtTheSameWidth() throws {
        let picture = CGRect(x: 0, y: 30, width: 320, height: 120)
        let source = try #require(context.createCGImage(letterboxed(CGSize(width: 320, height: 180), picture: picture),
                                                        from: CGRect(x: 0, y: 0, width: 320, height: 180)))
        let geometry = DisplayGeometry(crop: CGRect(x: 0, y: 30.0 / 180, width: 1, height: 120.0 / 180), pixelAspect: 1.5)
        let thumbnail = try #require(geometry.thumbnail(of: source, context: context))
        #expect(thumbnail.width == 320)
        #expect(thumbnail.height == 80)   // 320 / (320 × 1.5 / 120)
        #expect(BlackBars.contentRect(of: CIImage(cgImage: thumbnail), context: context).map { approximately($0, full) } == true)
    }

    @Test func theIdentityLeavesTheThumbnailAlone() throws {
        let source = try #require(context.createCGImage(letterboxed(CGSize(width: 160, height: 90), picture: CGRect(x: 0, y: 0, width: 160, height: 90)),
                                                        from: CGRect(x: 0, y: 0, width: 160, height: 90)))
        #expect(DisplayGeometry.identity.thumbnail(of: source, context: context) === source)
    }
}

@Suite struct BlackBarsTests {
    private let hd = CGSize(width: 1920, height: 1080)

    @Test func findsLetterboxBarsTheRightWayUp() {
        // Different bars top (200) and bottom (80) catch a flipped bitmap.
        let rect = BlackBars.contentRect(of: letterboxed(hd, picture: CGRect(x: 0, y: 80, width: 1920, height: 800)), context: context)
        #expect(approximately(rect, CGRect(x: 0, y: 80.0 / 1080, width: 1, height: 800.0 / 1080)))
    }

    @Test func findsPillarboxBars() {
        let rect = BlackBars.contentRect(of: letterboxed(hd, picture: CGRect(x: 240, y: 0, width: 1440, height: 1080)), context: context)
        #expect(approximately(rect, CGRect(x: 0.125, y: 0, width: 0.75, height: 1)))
    }

    @Test func aBlackOrMostlyDarkFrameTellsNothing() {
        #expect(BlackBars.contentRect(of: letterboxed(hd, picture: .zero), context: context) == nil)
        let spot = letterboxed(hd, picture: CGRect(x: 900, y: 500, width: 100, height: 60))
        #expect(BlackBars.contentRect(of: spot, context: context) == nil)
    }

    @Test func aDimLineAtTheBarEdgeIsPartOfTheBar() {
        // The encoder's smear: one row each side at a third of the picture's brightness.
        let picture = CGRect(x: 0, y: 80, width: 1920, height: 800)
        let smear = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
        let image = smear.cropped(to: CGRect(x: 0, y: 79, width: 1920, height: 1))
            .composited(over: smear.cropped(to: CGRect(x: 0, y: 880, width: 1920, height: 1)))
            .composited(over: letterboxed(hd, picture: picture))
        #expect(approximately(BlackBars.contentRect(of: image, context: context), CGRect(x: 0, y: 80.0 / 1080, width: 1, height: 800.0 / 1080)))
    }

    @Test func combiningTakesTheBoxAroundAllFramesAndSkipsDarkOnes() {
        let darkScene = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)   // a dark scene looks like bigger bars
        let bright = CGRect(x: 0, y: 0.1, width: 1, height: 0.8)
        #expect(BlackBars.combine([darkScene, nil, bright]) == bright)
        #expect(BlackBars.combine([nil, nil]) == nil)
    }

    @Test func thinEdgesAreNotBars() {
        #expect(BlackBars.combine([CGRect(x: 0.004, y: 0.005, width: 0.992, height: 0.99)]) == nil)
        let letterbox = BlackBars.combine([CGRect(x: 0.004, y: 0.1, width: 0.992, height: 0.8)])
        #expect(letterbox == CGRect(x: 0, y: 0.1, width: 1, height: 0.8))
    }

    @Test func theFileSampleAspectIsRead() throws {
        #expect(abs(try MediaSource(url: Fixtures.url(Fixtures.anamorphic)).sampleAspect - 64.0 / 45) < 0.0001)
        #expect(try MediaSource(url: Fixtures.url(Fixtures.withAudio)).sampleAspect == 1)
    }

    @Test func theSamplerFindsTheFixtureBars() throws {
        let (source, index) = try openIndexed(Fixtures.anamorphic)
        let crop = CropSampler(url: source.url, index: index, rotationClockwise: 0).detect(samples: 10)
        #expect(approximately(crop, CGRect(x: 0, y: 88.0 / 576, width: 1, height: 400.0 / 576)))
        // Keyframes 250 and 500 light the frame-number strip that is all black in frame 0: no bars over the file.
        let (plain, plainIndex) = try openIndexed(Fixtures.h264)
        #expect(CropSampler(url: plain.url, index: plainIndex, rotationClockwise: 0).detect(samples: 10) == nil)
    }
}
