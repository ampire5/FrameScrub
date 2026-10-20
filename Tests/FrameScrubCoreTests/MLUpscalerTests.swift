import CoreImage
import Testing
import VideoToolbox
@testable import FrameScrubCore

@Suite struct MLUpscalerTests {
    /// The model status does not depend on the image size.
    static var modelReady: Bool { MLUpscaler.availability(width: 64, height: 64) == .ready }

    @Test func limitMatchesTheMeasuredConfigurationLimits() {
        for (w, h, fits) in [(1920, 1080, true), (1080, 1920, true), (1088, 1920, true), (1024, 1024, true), (16, 16, true),
                             (1921, 1081, false), (2048, 1152, false), (2560, 1440, false), (2000, 2000, false), (0, 10, false)] {
            #expect(MLUpscaler.fits(width: w, height: h) == fits, "\(w)x\(h)")
        }
    }

    @Test func largeSourcesAreTooLarge() {
        #expect(MLUpscaler.availability(width: 3840, height: 2160) == .tooLarge)
    }

    @Test func fitsAgreesWithTheSystemConfiguration() throws {
        for (w, h) in [(1920, 1080), (1921, 1081), (1088, 1920), (2000, 2000), (640, 360)] {
            let config = VTSuperResolutionScalerConfiguration(
                frameWidth: w, frameHeight: h, scaleFactor: 4, inputType: .image, usePrecomputedFlow: false,
                qualityPrioritization: .normal, revision: VTSuperResolutionScalerConfiguration.defaultRevision)
            #expect((config != nil) == MLUpscaler.fits(width: w, height: h), "\(w)x\(h)")
        }
    }

    @Test func lanczosUpscalerNeverFallsBack() {
        let result = FrameUpscaler.upscale(markerImage(), scale: 2, upscaler: .lanczos, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason == nil)
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 128, height: 128))
    }

    @Test func scaleOneIsAPassThrough() {
        let image = markerImage()
        let result = FrameUpscaler.upscale(image, scale: 1, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.image == image)
        #expect(result.fallbackReason == nil)
    }

    @Test func hdrOutputFallsBackWithAReason() {
        let result = FrameUpscaler.upscale(markerImage(), scale: 4, upscaler: .ml, hdrOutput: true, context: CIContext())
        #expect(result.fallbackReason == "HDR output")
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 256, height: 256))
    }

    @Test func tooLargeSourceFallsBackWithAReason() {
        let big = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 2000, height: 1000))
        let result = FrameUpscaler.upscale(big, scale: 2, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason == "source larger than 1920 px")
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 4000, height: 2000))
    }

    @Test(.enabled(if: !MLUpscalerTests.modelReady, "the model is installed: mlUpscaleProducesAFourTimesLargerImage runs instead"))
    func missingModelFallsBackWithAReason() {
        let result = FrameUpscaler.upscale(markerImage(), scale: 2, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason != nil)
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 128, height: 128))
    }

    /// Runs only where the Apple model is installed (it needs a one-time download).
    @Test(.enabled(if: MLUpscalerTests.modelReady, "Apple super-resolution model is not downloaded"))
    func mlUpscaleProducesAFourTimesLargerImage() {
        let image = markerImage()
        let result = FrameUpscaler.upscale(image, scale: 4, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason == nil)
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 256, height: 256))
        let topLeft = samplePixel(result.image, x: 20, y: 20)
        let bottomLeft = samplePixel(result.image, x: 20, y: 236)
        #expect(topLeft[0] > 150 && topLeft[2] < 120)        // red on top
        #expect(bottomLeft[2] > 150 && bottomLeft[0] < 120)  // blue at the bottom
        let two = FrameUpscaler.upscale(image, scale: 2, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(two.image.extent == CGRect(x: 0, y: 0, width: 128, height: 128))
    }

    @Test func resizeDownscalesWithLanczosAndNeverFallsBack() {
        let result = FrameUpscaler.resize(markerImage(), to: CGSize(width: 32, height: 32), upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason == nil)
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 32, height: 32))
    }

    @Test func resizeToTheSameSizeIsAPassThrough() {
        let image = markerImage()
        let result = FrameUpscaler.resize(image, to: image.extent.size, upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.image == image)
        #expect(result.fallbackReason == nil)
    }

    @Test func resizeToANonIntegerFactorHitsTheExactTarget() {
        let result = FrameUpscaler.resize(markerImage(), to: CGSize(width: 192, height: 192), upscaler: .lanczos, hdrOutput: false, context: CIContext())
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 192, height: 192))
        #expect(result.fallbackReason == nil)
    }

    @Test func resizeBeyondFourTimesStillReachesTheTarget() {
        let result = FrameUpscaler.resize(markerImage(), to: CGSize(width: 640, height: 640), upscaler: .ml, hdrOutput: true, context: CIContext())
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 640, height: 640))
        #expect(result.fallbackReason == "HDR output")
    }

    @Test(.enabled(if: MLUpscalerTests.modelReady, "Apple super-resolution model is not downloaded"))
    func mlResizeToThreeTimesUsesTheNetworkThenLanczos() {
        let result = FrameUpscaler.resize(markerImage(), to: CGSize(width: 192, height: 192), upscaler: .ml, hdrOutput: false, context: CIContext())
        #expect(result.fallbackReason == nil)
        #expect(result.image.extent == CGRect(x: 0, y: 0, width: 192, height: 192))
    }
}
