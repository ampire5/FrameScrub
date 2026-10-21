import CoreImage
import Testing
@testable import FrameScrubCore

/// Renders to sRGB RGBA8 and returns the pixel at (x, y), y counted from the top.
func samplePixel(_ image: CIImage, x: Int, y: Int, context: CIContext = CIContext()) -> [UInt8] {
    var pixel = [UInt8](repeating: 0, count: 4)
    let top = Int(image.extent.maxY) - 1 - y
    context.render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x + Int(image.extent.minX), y: top, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    return pixel
}

/// 64×64 test picture: top-left red, top-right green, bottom-left blue, bottom-right white.
func markerImage() -> CIImage {
    func block(_ color: CIColor, _ x: Int, _ y: Int) -> CIImage {
        CIImage(color: color).cropped(to: CGRect(x: x, y: y, width: 32, height: 32))
    }
    return block(CIColor(red: 1, green: 0, blue: 0), 0, 32)
        .composited(over: block(CIColor(red: 0, green: 1, blue: 0), 32, 32))
        .composited(over: block(CIColor(red: 0, green: 0, blue: 1), 0, 0))
        .composited(over: block(CIColor(red: 1, green: 1, blue: 1), 32, 0))
}

@Suite struct ImageScalingTests {
    @Test func lanczosToSizeHasExactSizeAndOrigin() {
        let scaled = ImageScaling.lanczos(markerImage(), to: CGSize(width: 192, height: 192))
        #expect(scaled.extent == CGRect(x: 0, y: 0, width: 192, height: 192))
        let down = ImageScaling.lanczos(markerImage(), to: CGSize(width: 16, height: 16))
        #expect(down.extent == CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    @Test func lanczosKeepsOrientation() {
        let scaled = ImageScaling.lanczos(markerImage(), to: CGSize(width: 128, height: 128))
        let topLeft = samplePixel(scaled, x: 10, y: 10)
        let bottomLeft = samplePixel(scaled, x: 10, y: 118)
        #expect(topLeft[0] > 200 && topLeft[2] < 80)       // red
        #expect(bottomLeft[2] > 200 && bottomLeft[0] < 80) // blue
    }

    @Test func sharpenAmountZeroIsIdentity() {
        let image = markerImage()
        #expect(ImageScaling.sharpened(image, amount: 0) == image)
    }

    @Test func sharpenIncreasesEdgeContrast() {
        // Grey step edge: the dark side next to the edge gets darker, the bright side brighter.
        let dark = CIImage(color: CIColor(red: 0.3, green: 0.3, blue: 0.3)).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64))
        let bright = CIImage(color: CIColor(red: 0.7, green: 0.7, blue: 0.7)).cropped(to: CGRect(x: 32, y: 0, width: 32, height: 64))
        let edge = bright.composited(over: dark)
        let sharp = ImageScaling.sharpened(edge, amount: 1)
        #expect(sharp.extent == edge.extent)
        let before = samplePixel(edge, x: 31, y: 32)[0]
        let after = samplePixel(sharp, x: 31, y: 32)[0]
        #expect(after < before)
        // Flat areas unchanged, up to Core Image's rounding (one level off on Intel and under Rosetta).
        #expect(abs(Int(samplePixel(sharp, x: 2, y: 32)[0]) - Int(samplePixel(edge, x: 2, y: 32)[0])) <= 1)
    }
}
