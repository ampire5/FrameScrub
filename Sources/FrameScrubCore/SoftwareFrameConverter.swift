import CFFmpeg
import CoreVideo

/// Converts software-decoded frames to IOSurface-backed NV12 (8-bit) or P010 (>8-bit) buffers,
/// so the rest of the pipeline sees the same pixel formats as VideoToolbox produces. Full-range
/// sources (color_range JPEG or a yuvj* format) get the full-range variants and their sample
/// values pass through unchanged; everything else is labelled video range.
final class SoftwareFrameConverter {
    private var sws: UnsafeMutablePointer<SwsContext>?
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0
    private var poolFormat: OSType = 0

    deinit { sws_freeContext(sws) }

    func convert(_ frame: UnsafePointer<AVFrame>) throws -> CVPixelBuffer {
        let width = Int(frame.pointee.width)
        let height = Int(frame.pointee.height)
        let highBitDepth = cff_pix_fmt_depth(frame.pointee.format) > 8
        let fullRange = Self.isFullRange(frame)
        let cvFormat = highBitDepth
            ? (fullRange ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            : (fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        let avFormat = highBitDepth ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12

        if pool == nil || poolWidth != width || poolHeight != height || poolFormat != cvFormat {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: cvFormat,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
            poolWidth = width
            poolHeight = height
            poolFormat = cvFormat
        }

        var created: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created) == kCVReturnSuccess,
              let buffer = created else {
            throw FFmpegError(-1, "allocate pixel buffer")
        }

        sws = sws_getCachedContext(sws, Int32(width), Int32(height),
                                   AVPixelFormat(rawValue: frame.pointee.format),
                                   Int32(width), Int32(height), avFormat,
                                   Int32(bitPattern: SWS_BILINEAR.rawValue), nil, nil, nil)
        guard let sws else { throw FFmpegError(-1, "create pixel converter") }
        try setRange(sws, full: fullRange)

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let result = cff_sws_scale_frame(
            sws, frame,
            CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)),
            CVPixelBufferGetBaseAddressOfPlane(buffer, 1)?.assumingMemoryBound(to: UInt8.self),
            Int32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)))
        try check(result, "convert pixels")
        return buffer
    }

    private static let jpegFormats = Set([AV_PIX_FMT_YUVJ420P, AV_PIX_FMT_YUVJ422P, AV_PIX_FMT_YUVJ444P,
                                          AV_PIX_FMT_YUVJ440P, AV_PIX_FMT_YUVJ411P].map(\.rawValue))

    private static func isFullRange(_ frame: UnsafePointer<AVFrame>) -> Bool {
        frame.pointee.color_range == AVCOL_RANGE_JPEG || jpegFormats.contains(frame.pointee.format)
    }

    /// Makes source and destination ranges equal so swscale copies sample values unchanged
    /// (it would otherwise expand or compress them). Only touches the context when needed.
    private func setRange(_ sws: UnsafeMutablePointer<SwsContext>, full: Bool) throws {
        var invTable: UnsafeMutablePointer<Int32>?
        var table: UnsafeMutablePointer<Int32>?
        var srcRange: Int32 = 0, dstRange: Int32 = 0
        var brightness: Int32 = 0, contrast: Int32 = 0, saturation: Int32 = 0
        try check(sws_getColorspaceDetails(sws, &invTable, &srcRange, &table, &dstRange,
                                           &brightness, &contrast, &saturation), "read pixel converter range")
        let wanted: Int32 = full ? 1 : 0
        guard srcRange != wanted || dstRange != wanted else { return }
        try check(sws_setColorspaceDetails(sws, invTable, wanted, table, wanted, brightness, contrast, saturation),
                  "set pixel converter range")
    }
}
