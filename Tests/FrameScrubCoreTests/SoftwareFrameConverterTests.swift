import CFFmpeg
import CoreVideo
import Testing
@testable import FrameScrubCore

/// Builds AVFrames by hand (no fixture needed) and checks the range the converter picks and
/// that sample values pass through unchanged.
@Suite struct SoftwareFrameConverterTests {
    private struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let format: AVPixelFormat
        let range: AVColorRange
        let luma: Int
        let expectedFormat: OSType
        var testDescription: String { name }
    }

    private static let cases: [Case] = [
        Case(name: "yuv420p full", format: AV_PIX_FMT_YUV420P, range: AVCOL_RANGE_JPEG, luma: 255,
             expectedFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        Case(name: "yuvj420p", format: AV_PIX_FMT_YUVJ420P, range: AVCOL_RANGE_UNSPECIFIED, luma: 255,
             expectedFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
        Case(name: "yuv420p10 full", format: AV_PIX_FMT_YUV420P10LE, range: AVCOL_RANGE_JPEG, luma: 1023,
             expectedFormat: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange),
        Case(name: "yuv420p video", format: AV_PIX_FMT_YUV420P, range: AVCOL_RANGE_MPEG, luma: 235,
             expectedFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        Case(name: "yuv420p unspecified", format: AV_PIX_FMT_YUV420P, range: AVCOL_RANGE_UNSPECIFIED, luma: 235,
             expectedFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        Case(name: "yuv420p10 video", format: AV_PIX_FMT_YUV420P10LE, range: AVCOL_RANGE_MPEG, luma: 940,
             expectedFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange),
    ]

    @Test(arguments: cases)
    private func keepsRangeAndValues(_ c: Case) throws {
        let width = 64, height = 32
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let f = try #require(frame)
        f.pointee.width = Int32(width)
        f.pointee.height = Int32(height)
        f.pointee.format = c.format.rawValue
        f.pointee.color_range = c.range
        try #require(av_frame_get_buffer(f, 0) == 0)
        let tenBit = c.format == AV_PIX_FMT_YUV420P10LE
        let neutral = tenBit ? 512 : 128
        let planes = [f.pointee.data.0, f.pointee.data.1, f.pointee.data.2]
        let strides = [f.pointee.linesize.0, f.pointee.linesize.1, f.pointee.linesize.2]
        for plane in 0..<3 {
            let rows = plane == 0 ? height : height / 2
            let columns = plane == 0 ? width : width / 2
            let value = plane == 0 ? c.luma : neutral
            let base = try #require(planes[plane])
            let stride = Int(strides[plane])
            for y in 0..<rows {
                for x in 0..<columns {
                    if tenBit {
                        (base + y * stride).withMemoryRebound(to: UInt16.self, capacity: columns) { $0[x] = UInt16(value) }
                    } else {
                        base[y * stride + x] = UInt8(value)
                    }
                }
            }
        }

        let buffer = try SoftwareFrameConverter().convert(f)
        #expect(CVPixelBufferGetPixelFormatType(buffer) == c.expectedFormat)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let sample = tenBit
            ? Int(luma.load(fromByteOffset: 16 * lumaStride + 2 * 32, as: UInt16.self) >> 6)
            : Int(luma.load(fromByteOffset: 16 * lumaStride + 32, as: UInt8.self))
        #expect(abs(sample - c.luma) <= (tenBit ? 4 : 1), "luma \(sample), expected \(c.luma)")
    }
}
