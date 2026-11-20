import AVFoundation
import CoreImage
import IOSurface
import Metal
import VideoToolbox

let packedFormat = kCVPixelFormatType_Lossless_420YpCbCr10PackedBiPlanarVideoRange
let p010Format = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

struct BenchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func fourCC(_ code: OSType) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }, encoding: .ascii) ?? "?"
}

func surfaceSize(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferGetIOSurface(buffer).map { IOSurfaceGetAllocSize($0.takeUnretainedValue()) } ?? 0
}

private final class DecodedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(CMTime, CVPixelBuffer)] = []
    private var firstError: OSStatus = 0

    func append(status: OSStatus, image: CVImageBuffer?, pts: CMTime) {
        lock.withLock {
            if status != 0 && firstError == 0 { firstError = status }
            if let image { frames.append((pts, image)) }
        }
    }

    func result() throws -> [(CMTime, CVPixelBuffer)] {
        try lock.withLock {
            guard firstError == 0 else { throw BenchError("VT decode callback status \(firstError)") }
            return frames.sorted { $0.0 < $1.0 }
        }
    }
}

func decode(_ url: URL, format: OSType, packets: Int) async throws -> [(CMTime, CVPixelBuffer)] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first,
          let description = try await track.load(.formatDescriptions).first else {
        throw BenchError("Missing compressed video track")
    }
    let reader = try AVAssetReader(asset: asset)
    let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    source.alwaysCopiesSampleData = false
    reader.add(source)
    guard reader.startReading() else { throw reader.error ?? BenchError("AVAssetReader refused the source") }
    defer { reader.cancelReading() }

    let attributes = [kCVPixelBufferPixelFormatTypeKey: format,
                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                      kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder: true] as CFDictionary
    var session: VTDecompressionSession?
    let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: description,
                                             decoderSpecification: specification, imageBufferAttributes: attributes,
                                             outputCallback: nil, decompressionSessionOut: &session)
    guard status == 0, let session else { throw BenchError("VT create for \(fourCC(format)) status \(status)") }
    defer { VTDecompressionSessionInvalidate(session) }
    let output = DecodedOutput()
    var submitted = 0
    while submitted < packets {
        let outcome: (OSStatus, Bool)? = autoreleasepool {
            guard let sample = source.copyNextSampleBuffer() else { return nil }
            // AVAssetReader emits zero-sample markers for edit boundaries.
            guard CMSampleBufferGetNumSamples(sample) > 0 else { return (0, false) }
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                            flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) {
                status, _, image, pts, _ in
                output.append(status: status, image: image, pts: pts)
            }
            return (status, true)
        }
        guard let (decodeStatus, consumed) = outcome else { break }
        guard decodeStatus == 0 else { throw BenchError("VT packet for \(fourCC(format)) status \(decodeStatus)") }
        if consumed { submitted += 1 }
    }
    VTDecompressionSessionFinishDelayedFrames(session)
    VTDecompressionSessionWaitForAsynchronousFrames(session)
    var hardware: CFBoolean?
    let hardwareStatus = withUnsafeMutablePointer(to: &hardware) {
        VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                              allocator: nil, valueOut: UnsafeMutableRawPointer($0))
    }
    guard hardwareStatus == 0, let hardware, CFBooleanGetValue(hardware) else {
        throw BenchError("No hardware acceleration reported for \(fourCC(format))")
    }
    let frames = try output.result()
    print("requested=\(fourCC(format)) hardware=true count=\(frames.count)")
    guard !frames.isEmpty, frames.allSatisfy({ CVPixelBufferGetPixelFormatType($0.1) == format }) else {
        throw BenchError("VT delivered formats \(Set(frames.map { fourCC(CVPixelBufferGetPixelFormatType($0.1)) }))")
    }
    return frames
}

func checkRendering(reference: CVPixelBuffer, packed: CVPixelBuffer, context: CIContext) throws {
    let width = CVPixelBufferGetWidth(reference)
    let height = CVPixelBufferGetHeight(reference)
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let rowBytes = width * 8
    func pixels(_ buffer: CVPixelBuffer) -> Data {
        var bytes = Data(count: rowBytes * height)
        bytes.withUnsafeMutableBytes {
            context.render(CIImage(cvPixelBuffer: buffer), toBitmap: $0.baseAddress!,
                           rowBytes: rowBytes, bounds: bounds, format: .RGBAh, colorSpace: color)
        }
        return bytes
    }
    let a = pixels(reference)
    let b = pixels(packed)
    var differences = 0
    var maxDelta: Float = 0
    var totalDelta: Double = 0
    a.withUnsafeBytes { left in
        b.withUnsafeBytes { right in
            let ref = left.bindMemory(to: UInt16.self)
            let test = right.bindMemory(to: UInt16.self)
            for i in ref.indices where ref[i] != test[i] {
                let value = abs(Float(Float16(bitPattern: ref[i])) - Float(Float16(bitPattern: test[i])))
                differences += 1
                maxDelta = max(maxDelta, value)
                totalDelta += Double(value)
            }
        }
    }
    print(String(format: "rgba16f_different=%d rgba16f_max_delta=%.7f rgba16f_mean_delta=%.9f",
                 differences, maxDelta, totalDelta / Double(a.count / 2)))
    guard a.prefix(1024).contains(where: { $0 != 0 }) else {
        throw BenchError("Rendered surface is blank")
    }
}
func checkExactSamples(reference: CVPixelBuffer, packed: CVPixelBuffer) throws {
    var transfer: VTPixelTransferSession?
    guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer) == 0,
          let transfer else { throw BenchError("Could not create lossless round-trip transfer session") }
    defer { VTPixelTransferSessionInvalidate(transfer) }
    var restored: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary] as CFDictionary
    let width = CVPixelBufferGetWidth(reference)
    let height = CVPixelBufferGetHeight(reference)
    guard CVPixelBufferCreate(nil, width, height, p010Format, attributes, &restored) == 0,
          let restored else { throw BenchError("Could not allocate P010 verification surface") }
    CVBufferPropagateAttachments(reference, restored)
    let status = VTPixelTransferSessionTransferImage(transfer, from: packed, to: restored)
    guard status == 0 else { throw BenchError("Packed-to-P010 transfer status \(status)") }

    guard CVPixelBufferLockBaseAddress(reference, .readOnly) == 0 else {
        throw BenchError("Could not lock P010 reference")
    }
    defer { CVPixelBufferUnlockBaseAddress(reference, .readOnly) }
    guard CVPixelBufferLockBaseAddress(restored, .readOnly) == 0 else {
        throw BenchError("Could not lock restored P010")
    }
    defer { CVPixelBufferUnlockBaseAddress(restored, .readOnly) }
    for plane in 0..<2 {
        let a = CVPixelBufferGetBaseAddressOfPlane(reference, plane)!
        let b = CVPixelBufferGetBaseAddressOfPlane(restored, plane)!
        let aStride = CVPixelBufferGetBytesPerRowOfPlane(reference, plane)
        let bStride = CVPixelBufferGetBytesPerRowOfPlane(restored, plane)
        var unequal = 0
        var maxDelta = 0
        for row in 0..<CVPixelBufferGetHeightOfPlane(reference, plane) {
            let src = (a + row * aStride).assumingMemoryBound(to: UInt16.self)
            let dst = (b + row * bStride).assumingMemoryBound(to: UInt16.self)
            for index in 0..<width {
                let delta = abs(Int(src[index] >> 6) - Int(dst[index] >> 6))
                if delta > 0 {
                    unequal += 1
                    maxDelta = max(maxDelta, delta)
                }
            }
        }
        guard unequal == 0 else {
            throw BenchError("P010 round trip changed \(unequal) active samples in plane \(plane), max delta \(maxDelta)")
        }
    }
}
