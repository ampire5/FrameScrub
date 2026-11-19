import Compression
import CoreVideo
import Darwin

enum Mode: String, CaseIterable {
    case current, lz4, packed
#if NV12_CODECS
    case appleRaw = "apple-raw"
    case bitmap
    case liblz4
    case rowDelta = "row-delta"
    case zstd
    case bitpack
#endif

    func supports(depth: Int) -> Bool {
        switch self {
        case .current, .lz4: return true
        case .packed: return depth == 10
#if NV12_CODECS
        default: return depth == 8
#endif
        }
    }

    var algorithm: compression_algorithm {
#if NV12_CODECS
        if self == .appleRaw { return COMPRESSION_LZ4_RAW }
        if self == .bitmap { return COMPRESSION_LZBITMAP }
#endif
        return COMPRESSION_LZ4
    }

#if NV12_CODECS
    var method: NV12Method? {
        switch self {
        case .liblz4: return NV12LZ4
        case .rowDelta: return NV12RowsLZ4
        case .zstd: return NV12Zstd
        case .bitpack: return NV12Bitpack
        default: return nil
        }
    }
#endif
}

struct Format {
    let width: Int
    let height: Int
    let tenBit: Bool
    var rowBytes: Int { width * (tenBit ? 2 : 1) }
    var frameBytes: Int { rowBytes * (height + height / 2) }

    func makeBuffer() -> CVPixelBuffer {
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary
        let type = tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
                           : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, type, attributes, &buffer) == kCVReturnSuccess)
        return buffer!
    }

    func planes(_ buffer: CVPixelBuffer,
                _ visit: (Int, UnsafeMutableRawPointer, Int, Int) -> Void) {
        for plane in 0..<2 {
            visit(plane, CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!,
                  CVPixelBufferGetBytesPerRowOfPlane(buffer, plane),
                  CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    }

    func copy(_ source: UnsafeRawPointer, to buffer: CVPixelBuffer) {
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        planes(buffer) { plane, base, stride, rows in
            let input = source + (plane == 0 ? 0 : rowBytes * height)
            for row in 0..<rows {
                memcpy(base + row * stride, input + row * rowBytes, rowBytes)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }

    func verify(_ buffer: CVPixelBuffer, against source: UnsafeRawPointer) {
        precondition(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        planes(buffer) { plane, base, stride, rows in
            let expected = source + (plane == 0 ? 0 : rowBytes * height)
            for row in 0..<rows {
                precondition(memcmp(base + row * stride, expected + row * rowBytes, rowBytes) == 0,
                             "Round trip changed pixels")
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
    }
}

final class Payload {
    let bytes: UnsafeMutableRawPointer
    let count: Int
    let yBytes: Int
    let raw: Bool
    var allocation: Int { malloc_size(bytes) }

    init(copying source: UnsafeRawPointer, count: Int, yBytes: Int, raw: Bool = false) {
        self.count = count
        self.yBytes = yBytes
        self.raw = raw
        bytes = malloc(count)!
        memcpy(bytes, source, count)
    }

    deinit { free(bytes) }
}

struct Codec {
    let format: Format
    let mode: Mode

    var decodeWorkBufferSize: Int {
#if NV12_CODECS
        if mode.method != nil { return 1 }
#endif
        return max(compression_decode_scratch_buffer_size(mode.algorithm), 1)
    }

    var workBufferSize: Int {
#if NV12_CODECS
        if mode == .rowDelta { return format.frameBytes }
#endif
        return max(compression_encode_scratch_buffer_size(mode.algorithm),
                   compression_decode_scratch_buffer_size(mode.algorithm), 1)
    }

    private func encodePlane(_ source: UnsafeRawPointer, to target: UnsafeMutableRawPointer,
                             work: UnsafeMutableRawPointer, rows: Int, chroma: Bool) -> Int {
#if NV12_CODECS
        if let method = mode.method {
            return nv12_encode_plane(method, source.assumingMemoryBound(to: UInt8.self),
                                     target.assumingMemoryBound(to: UInt8.self),
                                     format.rowBytes, rows, chroma ? 1 : 0,
                                     work.assumingMemoryBound(to: UInt8.self))
        }
#endif
        let size = format.rowBytes * rows
        return compression_encode_buffer(target.assumingMemoryBound(to: UInt8.self), size,
                                         source.assumingMemoryBound(to: UInt8.self), size, work, mode.algorithm)
    }

    private func decodePlane(_ source: UnsafeRawPointer, bytes: Int, to target: UnsafeMutableRawPointer,
                             work: UnsafeMutableRawPointer, rows: Int, chroma: Bool) -> Bool {
#if NV12_CODECS
        if let method = mode.method {
            return nv12_decode_plane(method, source.assumingMemoryBound(to: UInt8.self), bytes,
                                     target.assumingMemoryBound(to: UInt8.self),
                                     format.rowBytes, rows, chroma ? 1 : 0) == 1
        }
#endif
        let size = format.rowBytes * rows
        return compression_decode_buffer(target.assumingMemoryBound(to: UInt8.self), size,
                                         source.assumingMemoryBound(to: UInt8.self), bytes,
                                         work, mode.algorithm) == size
    }

    func encode(_ source: UnsafeRawPointer, into scratch: UnsafeMutableRawPointer,
                work: UnsafeMutableRawPointer) -> Payload {
        let ySize = format.rowBytes * format.height
        if mode == .packed {
            pack_p010(source.assumingMemoryBound(to: UInt16.self), scratch.assumingMemoryBound(to: UInt8.self),
                      format.frameBytes / 2)
            return Payload(copying: scratch, count: format.frameBytes * 5 / 8, yBytes: ySize * 5 / 8)
        }
        let y = encodePlane(source, to: scratch, work: work, rows: format.height, chroma: false)
        let uv = encodePlane(source + ySize, to: scratch + y, work: work, rows: format.height / 2, chroma: true)
        if y == 0 || uv == 0 || y + uv >= format.frameBytes {
            return Payload(copying: source, count: format.frameBytes, yBytes: ySize, raw: true)
        }
        return Payload(copying: scratch, count: y + uv, yBytes: y)
    }

    func restore(_ payload: Payload, to buffer: CVPixelBuffer, scratch: UnsafeMutableRawPointer,
                 work: UnsafeMutableRawPointer) {
        if payload.raw {
            format.copy(payload.bytes, to: buffer)
            return
        }
        precondition(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        format.planes(buffer) { plane, base, stride, rows in
            let input = payload.bytes + (plane == 0 ? 0 : payload.yBytes)
            if mode == .packed {
                let packedRowBytes = format.width * 5 / 4
                for row in 0..<rows {
                    unpack_p010((input + row * packedRowBytes).assumingMemoryBound(to: UInt8.self),
                                (base + row * stride).assumingMemoryBound(to: UInt16.self), format.width)
                }
                return
            }
            let inputBytes = plane == 0 ? payload.yBytes : payload.count - payload.yBytes
            let output = stride == format.rowBytes ? base : scratch
            let decoded = decodePlane(input, bytes: inputBytes, to: output, work: work, rows: rows, chroma: plane == 1)
            precondition(decoded, "Cache restore produced an incomplete plane")
            if output == scratch {
                for row in 0..<rows {
                    memcpy(base + row * stride, scratch + row * format.rowBytes, format.rowBytes)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
    }
}
