import Accelerate
import CoreVideo

/// Sharpness of a decoded frame for the sharp-frames export (sharp export spec §2). The luma, reduced to at most
/// 1920 px wide on the 0…255 scale, is cut into 8×6 tiles; a tile is as sharp as the weaker of its horizontal and
/// vertical detail (variance of the second derivative), so motion blur counts; the frame scores the mean of its
/// sharpest quarter of tiles, so a flat background does not. Only compared with other scores.
public enum SharpnessMeter {
    static let maxWidth = 1920
    static let columns = 8, rows = 6

    /// nil for pixel formats other than NV12 / P010 and frames too small to measure.
    public static func score(_ pixelBuffer: CVPixelBuffer) -> Double? {
        let tenBit: Bool
        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: tenBit = false
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: tenBit = true
        default: return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let factor = (width + maxWidth - 1) / maxWidth
        let w = width / factor, h = height / factor
        guard w - 2 >= columns, h - 2 >= rows else { return nil }
        var source = vImage_Buffer(data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                                   rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0))
        guard let luma = reduce(&source, tenBit: tenBit, factor: factor, width: w, height: h),
              let horizontal = secondDerivative(luma, width: w, height: h, kernel: [0, 0, 0, 1, -2, 1, 0, 0, 0]),
              let vertical = secondDerivative(luma, width: w, height: h, kernel: [0, 1, 0, 0, -2, 0, 0, 1, 0])
        else { return nil }
        let tiles = zip(tileVariances(horizontal, width: w - 2, height: h - 2),
                        tileVariances(vertical, width: w - 2, height: h - 2)).map { min($0, $1) }
        let sharpest = tiles.sorted(by: >).prefix(max(1, tiles.count / 4))
        return sharpest.reduce(0, +) / Double(sharpest.count)
    }

    /// The luma reduced to `width`×`height` (vImage antialiases when shrinking), as floats on the 0…255 scale.
    private static func reduce(_ source: inout vImage_Buffer, tenBit: Bool, factor: Int, width: Int, height: Int) -> [Float]? {
        let bytesPerPixel = tenBit ? 2 : 1
        var small = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        var luma = [Float](repeating: 0, count: width * height)
        let status = small.withUnsafeMutableBytes { smallBytes in
            luma.withUnsafeMutableBytes { lumaBytes -> vImage_Error in
                var reduced = vImage_Buffer(data: smallBytes.baseAddress, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * bytesPerPixel)
                var floats = vImage_Buffer(data: lumaBytes.baseAddress, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: width * 4)
                let flags = vImage_Flags(kvImageNoFlags)
                if tenBit {
                    // P010 keeps its 10 bits at the top of 16: dividing by 256 gives the 8-bit scale.
                    guard factor > 1 else { return vImageConvert_16UToF(&source, &floats, 0, 1.0 / 256, flags) }
                    let scaled = vImageScale_Planar16U(&source, &reduced, nil, flags)
                    guard scaled == kvImageNoError else { return scaled }
                    return vImageConvert_16UToF(&reduced, &floats, 0, 1.0 / 256, flags)
                }
                guard factor > 1 else { return vImageConvert_Planar8toPlanarF(&source, &floats, 255, 0, flags) }
                let scaled = vImageScale_Planar8(&source, &reduced, nil, flags)
                guard scaled == kvImageNoError else { return scaled }
                return vImageConvert_Planar8toPlanarF(&reduced, &floats, 255, 0, flags)
            }
        }
        return status == kvImageNoError ? luma : nil
    }

    /// Response of a 3×3 `kernel` over the pixels that have all eight neighbours, (width − 2)×(height − 2).
    private static func secondDerivative(_ luma: [Float], width: Int, height: Int, kernel: [Float]) -> [Float]? {
        let innerWidth = width - 2, innerHeight = height - 2
        var source = luma
        var edges = [Float](repeating: 0, count: innerWidth * innerHeight)
        let status = source.withUnsafeMutableBytes { sourceBytes in
            edges.withUnsafeMutableBytes { edgeBytes -> vImage_Error in
                var input = vImage_Buffer(data: sourceBytes.baseAddress, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width * 4)
                var output = vImage_Buffer(data: edgeBytes.baseAddress, height: vImagePixelCount(innerHeight),
                                           width: vImagePixelCount(innerWidth), rowBytes: innerWidth * 4)
                // The output starts at (1, 1) of the input, so the kernel never reaches past its border.
                return vImageConvolve_PlanarF(&input, &output, nil, 1, 1, kernel, 3, 3, 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return status == kvImageNoError ? edges : nil
    }

    /// Variance of each of the `columns`×`rows` tiles of a `width`×`height` image, row by row.
    private static func tileVariances(_ values: [Float], width: Int, height: Int) -> [Double] {
        let tileWidth = width / columns, tileHeight = height / rows
        var result: [Double] = []
        result.reserveCapacity(columns * rows)
        values.withUnsafeBufferPointer { pixels in
            for row in 0..<rows {
                for column in 0..<columns {
                    var sum: Float = 0, sumOfSquares: Float = 0
                    for y in row * tileHeight..<(row + 1) * tileHeight {
                        let start = pixels.baseAddress! + y * width + column * tileWidth
                        var mean: Float = 0, meanSquare: Float = 0
                        vDSP_meanv(start, 1, &mean, vDSP_Length(tileWidth))
                        vDSP_measqv(start, 1, &meanSquare, vDSP_Length(tileWidth))
                        sum += mean
                        sumOfSquares += meanSquare
                    }
                    let mean = sum / Float(tileHeight)
                    result.append(Double(max(0, sumOfSquares / Float(tileHeight) - mean * mean)))
                }
            }
        }
        return result
    }
}
