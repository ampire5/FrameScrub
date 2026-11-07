import CoreImage
public struct UpscaleResult {
    public let image: CIImage
    public let fallbackReason: String?
}
public enum FrameUpscaler {
    public static func resize(_ image: CIImage, to size: CGSize, upscaler: Upscaler, hdrOutput: Bool, context: CIContext) -> UpscaleResult {
        UpscaleResult(image: size == image.extent.size ? image : ImageScaling.lanczos(image, to: size), fallbackReason: nil)
    }
}
