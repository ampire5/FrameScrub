#if NV12_CODECS
import CoreVideo
import Darwin
import Foundation
import IOSurface

/// Owned by the benchmark's serial restore queue after initialization. Restored buffers
/// are handed back only after the main queue receives Metal's completion callback.
final class NV12DisplaySource: @unchecked Sendable {
    // The worker keeps the slot out of circulation until Metal completes.
    struct Lease: @unchecked Sendable {
        let buffer: CVPixelBuffer
    }

    private final class Storage {
        let address: UnsafeMutableRawPointer
        init(_ bytes: Int) { address = malloc(bytes)! }
        deinit { free(address) }
    }

    let cache = FrameCache(budgetBytes: 256 << 20)
    let format = Format(width: 3840, height: 2160, tenBit: false)
    let codec: Codec
    let queue = DispatchQueue(label: "FrameCacheBench.NV12Restore", qos: .userInitiated)
    private let scratch = Storage(1)
    private let work: Storage
    private var compressed: [Int: Payload] = [:]
    private var outputs: [CVPixelBuffer] = []

    private func newSurface() -> CVPixelBuffer {
        let buffer = format.makeBuffer()
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    init(url: URL, mode: Mode, mixed: Bool) throws {
        let codec = Codec(format: format, mode: mode)
        self.codec = codec
        // 4K NV12 has no stride delta. Restore can write directly into its locked
        // IOSurface, and none of the optional external decoders need extra scratch.
        work = Storage(codec.decodeWorkBufferSize)
        guard let file = fopen(url.path, "rb") else { throw BenchError("Cannot open raw NV12 frames") }
        defer { fclose(file) }
        let input = malloc(format.frameBytes)!
        let encodeScratch = malloc(format.frameBytes)!
        let encodeWork = malloc(codec.workBufferSize)!
        defer { free(input); free(encodeScratch); free(encodeWork) }
        guard fread(input, 1, format.frameBytes, file) == format.frameBytes else {
            throw BenchError("Could not read a full NV12 frame")
        }
        var bytes = 0
        if mode != .current {
            outputs = [newSurface(), newSurface()]
            for buffer in outputs {
                guard (0..<2).allSatisfy({ CVPixelBufferGetBytesPerRowOfPlane(buffer, $0) == format.rowBytes }) else {
                    throw BenchError("Unexpected NV12 restore stride")
                }
                bytes += surfaceSize(buffer)
            }
        }

        var number = 0
        repeat {
            let kept = autoreleasepool {
                if mode == .current || (mixed && (2...5).contains(number)) {
                    let buffer = newSurface()
                    let size = surfaceSize(buffer)
                    guard bytes + size <= cache.budgetBytes else { return false }
                    format.copy(input, to: buffer)
                    cache.insert(DecodedFrame(number: number, pts: Int64(number), pixelBuffer: buffer,
                                              dynamicRange: .sdr, byteSize: size))
                    bytes += size
                } else {
                    let payload = codec.encode(input, into: encodeScratch, work: encodeWork)
                    guard bytes + payload.allocation <= cache.budgetBytes else { return false }
                    codec.restore(payload, to: outputs[0], scratch: scratch.address, work: work.address)
                    format.verify(outputs[0], against: input)
                    compressed[number] = payload
                    bytes += payload.allocation
                }
                return true
            }
            if !kept { break }
            number += 1
        } while fread(input, 1, format.frameBytes, file) == format.frameBytes
        guard number >= 8 else { throw BenchError("NV12 source could not fill the trace window") }
        print(String(format: "cache_frames=%d charged_MiB=%.2f restored_surfaces=%d hot_frames=%d",
                     number, Double(bytes) / 1048576, outputs.count, cache.count))
    }

    func fetch(_ number: Int, slot: Int, complete: @escaping @Sendable (Lease?, Double) -> Void) {
        queue.async { [self] in
            let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let buffer: CVPixelBuffer?
            if let frame = cache.frame(number) {
                buffer = frame.pixelBuffer
            } else if let payload = compressed[number] {
                let output = outputs[slot]
                codec.restore(payload, to: output, scratch: scratch.address, work: work.address)
                buffer = output
            } else {
                buffer = nil
            }
            complete(buffer.map(Lease.init(buffer:)), Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e6)
        }
    }
}
#endif
