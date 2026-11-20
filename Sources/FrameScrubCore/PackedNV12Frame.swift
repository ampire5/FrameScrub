import CNV12Bitpack
import CoreVideo
import Darwin

/// Immutable, independently recoverable NV12 cache entry. Published frames keep their own IOSurface.
final class PackedNV12Frame: @unchecked Sendable {
    private let payload: UnsafeMutablePointer<UInt8>
    private let yBytes: Int
    private let totalBytes: Int
    private let width: Int
    private let height: Int
    private let format: OSType
    private let propagating: CFDictionary?
    private let local: CFDictionary?
    private let number: Int
    private let pts: Int64
    private let pictureType: Character?
    private let dynamicRange: DynamicRange
    let byteSize: Int

    static func supports(_ buffer: CVPixelBuffer) -> Bool {
        let type = CVPixelBufferGetPixelFormatType(buffer)
        return type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
            type == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }

    init?(_ frame: DecodedFrame) {
        let buffer = frame.pixelBuffer
        guard Self.supports(buffer), CVPixelBufferGetPlaneCount(buffer) == 2, CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let chromaRows = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let uvWidth = CVPixelBufferGetWidthOfPlane(buffer, 1) * 2
        let rawBytes = width * height + uvWidth * chromaRows
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1),
              let scratch = malloc(rawBytes)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        defer { free(scratch) }
        let first = fs_nv12_pack(y.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                 scratch, rawBytes, width, height, 0)
        guard first > 0 else { return nil }
        let second = fs_nv12_pack(uv.assumingMemoryBound(to: UInt8.self), CVPixelBufferGetBytesPerRowOfPlane(buffer, 1),
                                  scratch + first, rawBytes - first, uvWidth, chromaRows, 1)
        // Count the actual allocator size. A frame that saves no space stays in its original buffer.
        guard second > 0, first + second < frame.byteSize,
              let storage = malloc(first + second)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let charged = malloc_size(storage)
        guard charged < frame.byteSize else { free(storage); return nil }
        memcpy(storage, scratch, first + second)
        payload = storage
        yBytes = first
        totalBytes = first + second
        self.width = width
        self.height = height
        format = CVPixelBufferGetPixelFormatType(buffer)
        propagating = CVBufferCopyAttachments(buffer, .shouldPropagate)
        local = CVBufferCopyAttachments(buffer, .shouldNotPropagate)
        number = frame.number
        pts = frame.pts
        pictureType = frame.pictureType
        dynamicRange = frame.dynamicRange
        byteSize = charged
    }

    deinit { free(payload) }

    func restore() -> DecodedFrame? {
        var destination: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                     kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, width, height, format, attrs, &destination) == kCVReturnSuccess,
              let destination, restorePlanes(to: destination) else { return nil }
        if let propagating { CVBufferSetAttachments(destination, propagating, .shouldPropagate) }
        if let local { CVBufferSetAttachments(destination, local, .shouldNotPropagate) }
        return DecodedFrame(number: number, pts: pts, pixelBuffer: destination, dynamicRange: dynamicRange, pictureType: pictureType)
    }

    private func restorePlanes(to buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        return fs_nv12_unpack(payload, yBytes, y.assumingMemoryBound(to: UInt8.self),
                              CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), width, height, 0) == 1 &&
            fs_nv12_unpack(payload + yBytes, totalBytes - yBytes, uv.assumingMemoryBound(to: UInt8.self),
                           CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), CVPixelBufferGetWidthOfPlane(buffer, 1) * 2,
                           CVPixelBufferGetHeightOfPlane(buffer, 1), 1) == 1
    }
}
