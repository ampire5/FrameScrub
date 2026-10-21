import CoreImage
import CoreImage.CIFilterBuiltins

/// A frame reduced to 64×36 sRGB pixels (any aspect), enough to tell one scene from another.
public struct SceneSignature: Sendable, Equatable {
    static let width = 64, height = 36
    /// R, G, B bytes, row by row.
    let rgb: [UInt8]

    private static let context = CIContext(options: [.cacheIntermediates: false])

    public static func of(_ image: CIImage) -> SceneSignature {
        var source = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        // A plain linear shrink to 4× the size first: Lanczos over a whole 4K frame costs twice the CPU (3 ms against 1.4)
        // for a signature that differs by less than 0.4 of 255.
        let shrink = max(Double(width * 4) / source.extent.width, Double(height * 4) / source.extent.height)
        if shrink < 1 {
            let size = CGSize(width: (source.extent.width * shrink).rounded(), height: (source.extent.height * shrink).rounded())
            source = source.transformed(by: CGAffineTransform(scaleX: size.width / source.extent.width, y: size.height / source.extent.height))
                .cropped(to: CGRect(origin: .zero, size: size))
        }
        // Scaled while clamped, so the edge pixels are not blended with the transparent outside of the frame.
        let extent = source.extent
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = source.clampedToExtent()
        filter.scale = Float(Double(height) / extent.height)
        filter.aspectRatio = Float((Double(width) / extent.width) / (Double(height) / extent.height))
        let scaled = (filter.outputImage ?? image).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: width * 4, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))   // as seen, not linear
        var rgb = [UInt8]()
        rgb.reserveCapacity(width * height * 3)
        for pixel in stride(from: 0, to: rgba.count, by: 4) { rgb += rgba[pixel..<pixel + 3] }
        return SceneSignature(rgb: rgb)
    }

    /// Mean absolute difference per colour byte, 0…255.
    public func difference(_ other: SceneSignature) -> Double {
        var sum = 0
        for (a, b) in zip(rgb, other.rgb) { sum += abs(Int(a) - Int(b)) }
        return Double(sum) / Double(rgb.count)
    }

    /// Largest colour-byte difference of each of the 64×36 cells, row by row.
    public func cellDifferences(_ other: SceneSignature) -> [Int] {
        stride(from: 0, to: min(rgb.count, other.rgb.count), by: 3).map { (i: Int) -> Int in
            let red: Int = abs(Int(rgb[i]) - Int(other.rgb[i]))
            let green: Int = abs(Int(rgb[i + 1]) - Int(other.rgb[i + 1]))
            let blue: Int = abs(Int(rgb[i + 2]) - Int(other.rgb[i + 2]))
            return max(red, green, blue)
        }
    }

    /// Share of the picture, 0…1, whose cells differ from `other` by more than `noise` of 255 in some colour.
    public func changedShare(_ other: SceneSignature, noise: Int) -> Double {
        let cells = cellDifferences(other)
        return cells.isEmpty ? 0 : Double(cells.filter { $0 > noise }.count) / Double(cells.count)
    }
}

/// Finds scene cuts in the frames shown one after another (a jump counts too: it is compared with the
/// frame shown before it).
public struct SceneCutDetector: Sendable {
    /// Measured on 4K footage (2026-10-12): motion up to 29.7 in a fast trailer, usually below 20; hard cuts 31…135.
    /// A false cut costs one more analysis of the same scene, a missed one leaves the previous decision on the next scene.
    public static let defaultThreshold = 25.0

    public var threshold: Double
    private var previous: SceneSignature?

    public init(threshold: Double = defaultThreshold) {
        self.threshold = threshold
    }

    /// Whether `signature` starts a new scene; the first one after creation or `reset()` always does.
    public mutating func isCut(_ signature: SceneSignature) -> Bool {
        defer { previous = signature }
        guard let previous else { return true }
        return previous.difference(signature) >= threshold
    }

    public mutating func reset() {
        previous = nil
    }
}

/// Which shown frames go to the scene-cut detector: at most 30 a second (a signature costs about 1.4 ms of CPU
/// on 4K), each frame once, and a frame that comes too early is sent when its 1/30 s slot ends, so the frame
/// a scrub or jump stops on is always compared.
public struct SceneSampling: Sendable {
    public static let interval = 1.0 / 30

    public enum Decision: Equatable, Sendable {
        case now
        /// Try again after this many seconds, with whatever frame is then on screen.
        case later(Double)
        /// Already compared.
        case skip
    }

    private var lastAt = -Double.infinity
    private var lastFrame: Int?

    public init() {}

    public mutating func decide(frame: Int, at time: Double) -> Decision {
        guard frame != lastFrame else { return .skip }
        let wait = lastAt + Self.interval - time
        guard wait <= 1e-9 else { return .later(wait) }
        lastAt = time
        lastFrame = frame
        return .now
    }

    /// Another file or session: every frame counts again.
    public mutating func reset() {
        self = SceneSampling()
    }
}
