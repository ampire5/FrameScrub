import CoreImage
import CoreImage.CIFilterBuiltins

/// Core Image helpers shared by display and file output. All results keep the extent origin at (0, 0).
public enum ImageScaling {
    /// Lanczos resample by a uniform factor (antialiased when below 1).
    public static func lanczos(_ image: CIImage, scale: Double) -> CIImage {
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(scale)
        filter.aspectRatio = 1
        return origin(filter.outputImage ?? image)
    }

    /// Lanczos resample to exactly `size` pixels. The two axes are scaled separately, so a target whose
    /// sides were rounded independently still comes out exact.
    public static func lanczos(_ image: CIImage, to size: CGSize) -> CIImage {
        let vertical = size.height / image.extent.height
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = image
        filter.scale = Float(vertical)
        filter.aspectRatio = Float((size.width / image.extent.width) / vertical)   // horizontal = scale * aspectRatio
        let scaled = origin(filter.outputImage ?? image)
        return origin(scaled.cropped(to: CGRect(origin: scaled.extent.origin, size: size)))
    }

    /// Luminance sharpening; `amount` is the `sharpen` setting (0…1), 0 returns the image unchanged.
    public static func sharpened(_ image: CIImage, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = Float(min(max(amount, 0), 1))
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    static func origin(_ image: CIImage) -> CIImage {
        image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
}
