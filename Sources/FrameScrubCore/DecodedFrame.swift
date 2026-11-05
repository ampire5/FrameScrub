import CoreVideo

public enum DynamicRange: Sendable { case sdr, hlg, pq }

/// One decoded picture: IOSurface-backed NV12/P010 with colour attachments already set.
// Safety: the decoder completes pixels and attachments before publishing a frame. Consumers retain the buffer
// and only read it; callers constructing frames must follow the same freeze-after-publication contract.
// Replace this narrow SDK escape hatch when CoreVideo exposes an immutable Sendable buffer handle.
public struct DecodedFrame: @unchecked Sendable {
    public let number: Int
    public let pts: Int64
    public let pixelBuffer: CVPixelBuffer
    public let dynamicRange: DynamicRange
    public let byteSize: Int
    /// "I", "P" or "B" as the decoder reported it; nil when it did not say.
    public let pictureType: Character?

    public init(number: Int, pts: Int64, pixelBuffer: CVPixelBuffer, dynamicRange: DynamicRange,
                byteSize: Int? = nil, pictureType: Character? = nil) {
        self.number = number
        self.pictureType = pictureType
        self.pts = pts
        self.pixelBuffer = pixelBuffer
        self.dynamicRange = dynamicRange
        self.byteSize = byteSize ?? pixelBufferByteSize(pixelBuffer)
    }
}

public func pixelBufferByteSize(_ pb: CVPixelBuffer) -> Int {
    guard CVPixelBufferIsPlanar(pb) else {
        return CVPixelBufferGetBytesPerRow(pb) * CVPixelBufferGetHeight(pb)
    }
    return (0..<CVPixelBufferGetPlaneCount(pb)).reduce(0) {
        $0 + CVPixelBufferGetBytesPerRowOfPlane(pb, $1) * CVPixelBufferGetHeightOfPlane(pb, $1)
    }
}
