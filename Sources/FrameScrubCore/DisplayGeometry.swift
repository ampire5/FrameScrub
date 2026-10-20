import CoreGraphics
import CoreImage

/// What `a` cycles through. `auto` is the file's own pixel aspect with the black bars cut off.
public enum AspectMode: CaseIterable, Equatable, Sendable {
    case auto, noCrop, ratio16x9, ratio4x3, ratio235, squarePixels

    public var next: AspectMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// The whole picture is stretched to this width / height.
    var forcedRatio: Double? {
        switch self {
        case .ratio16x9: return 16.0 / 9
        case .ratio4x3: return 4.0 / 3
        case .ratio235: return 2.35
        case .auto, .noCrop, .squarePixels: return nil
        }
    }

    public var label: String {
        switch self {
        case .auto: return "auto"
        case .noCrop: return "no crop"
        case .ratio16x9: return "16:9"
        case .ratio4x3: return "4:3"
        case .ratio235: return "2.35:1"
        case .squarePixels: return "square pixels"
        }
    }
}

/// Which part of the upright picture is shown and how wide its pixels are: the same for the screen and for
/// saved frames.
public struct DisplayGeometry: Equatable, Sendable {
    /// The shown part of the upright picture, as fractions of its size (Core Image orientation: y up).
    public var crop: CGRect
    /// Width of one upright pixel relative to its height.
    public var pixelAspect: Double

    public static let identity = DisplayGeometry(crop: CGRect(x: 0, y: 0, width: 1, height: 1), pixelAspect: 1)

    public init(crop: CGRect, pixelAspect: Double) {
        self.crop = crop
        self.pixelAspect = pixelAspect
    }

    /// `sampleAspect` is the stream's SAR (coded orientation), `detectedCrop` the black-bar detector's result.
    public static func resolve(mode: AspectMode, upright: CGSize, rotationClockwise: Int, sampleAspect: Double,
                               detectedCrop: CGRect?) -> DisplayGeometry {
        let sar = sampleAspect > 0 && sampleAspect.isFinite ? sampleAspect : 1
        let fileAspect = rotationClockwise % 180 == 0 ? sar : 1 / sar
        let full = identity.crop
        if let ratio = mode.forcedRatio, upright.width > 0, upright.height > 0 {
            return DisplayGeometry(crop: full, pixelAspect: ratio / (upright.width / upright.height))
        }
        switch mode {
        case .auto: return DisplayGeometry(crop: detectedCrop ?? full, pixelAspect: fileAspect)
        case .noCrop: return DisplayGeometry(crop: full, pixelAspect: fileAspect)
        default: return identity
        }
    }

    /// The crop in pixels of a picture of `size`, on whole pixels.
    public func cropRect(in size: CGSize) -> CGRect {
        let x0 = (crop.minX * size.width).rounded(), x1 = (crop.maxX * size.width).rounded()
        let y0 = (crop.minY * size.height).rounded(), y1 = (crop.maxY * size.height).rounded()
        return CGRect(x: x0, y: y0, width: max(1, x1 - x0), height: max(1, y1 - y0))
    }

    /// Width / height of the shown picture for an upright picture of `size`.
    public func aspect(of size: CGSize) -> Double {
        let rect = cropRect(in: size)
        return rect.width * pixelAspect / rect.height
    }

    /// Size in square pixels: the cropped picture with the narrower side stretched (no detail is lost).
    public func displaySize(of size: CGSize) -> CGSize {
        let rect = cropRect(in: size)
        return pixelAspect >= 1
            ? CGSize(width: (rect.width * pixelAspect).rounded(), height: rect.height)
            : CGSize(width: rect.width, height: (rect.height / pixelAspect).rounded())
    }

    /// The shown part of `image` (extent origin at 0, 0), still with its own pixels.
    public func cropped(_ image: CIImage) -> CIImage {
        let rect = cropRect(in: image.extent.size)
        guard rect.size != image.extent.size else { return image }
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// The picture as shown, in square pixels at `displaySize`: for saved frames.
    public func applied(to image: CIImage) -> CIImage {
        let target = displaySize(of: image.extent.size)
        let shown = cropped(image)
        return shown.extent.size == target ? shown : ImageScaling.lanczos(shown, to: target)
    }

    /// A thumbnail (seek-bar preview) shown like the screen, at its own width; the identity returns it unchanged.
    public func thumbnail(of image: CGImage, context: CIContext) -> CGImage? {
        guard self != .identity else { return image }
        let source = CIImage(cgImage: image)
        let shown = displaySize(of: source.extent.size)
        let width = CGFloat(image.width)
        let target = CGSize(width: width, height: max(1, (width * shown.height / shown.width).rounded()))
        let output = ImageScaling.lanczos(cropped(source), to: target)
        return context.createCGImage(output, from: CGRect(origin: .zero, size: target))
    }

    /// One line for the stats.
    public func statusText(mode: AspectMode, upright: CGSize, sampleAspect: Double) -> String {
        let shown = displaySize(of: upright)
        let rect = cropRect(in: upright)
        var parts = ["Aspect: \(mode.label) \(String(format: "%.2f", shown.width / max(shown.height, 1))):1"]
        if sampleAspect != 1 { parts.append("SAR \(String(format: "%.3f", sampleAspect))") }
        if rect.size != upright {
            parts.append("crop \(Int(rect.width))x\(Int(rect.height)) of \(Int(upright.width))x\(Int(upright.height))")
        }
        return parts.joined(separator: " · ")
    }
}
