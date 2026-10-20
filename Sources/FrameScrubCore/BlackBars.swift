import CoreGraphics
import CoreImage
import Foundation

/// Finds letterbox / pillarbox bars: the box around everything that is not black. Results are fractions of
/// the picture in Core Image orientation (y up).
public enum BlackBars {
    /// A pixel is lit when one of its sRGB channels is above this (compressed black stays well below).
    static let litLevel: UInt8 = 40
    /// A row or column is picture when this share of its pixels is lit.
    static let litShare = 0.02
    /// A frame whose lit box is smaller than this share of a side is too dark to tell where the bars are.
    static let minimumContent = 0.2
    /// Bars thinner than this share of a side are left (edge artefacts, not letterboxing).
    static let minimumBar = 0.01
    /// Columns (or rows) the frame is reduced to before its rows (or columns) are measured.
    static let sampleSize = 256
    /// Up to this many lit lines at an edge of the box are dropped when each is less than half as bright as the
    /// line inside it: the encoder's smear of the bar edge, which would show as a grey line.
    static let smearLines = 2

    /// The lit box of one frame of RGBA8 pixels (rows top to bottom), or nil when it is too dark.
    public static func contentRect(rgba: [UInt8], width: Int, height: Int) -> CGRect? {
        guard width > 0, height > 0, rgba.count >= width * height * 4 else { return nil }
        var rowLit = [Int](repeating: 0, count: height), rowBrightness = [Int](repeating: 0, count: height)
        var columnLit = [Int](repeating: 0, count: width), columnBrightness = [Int](repeating: 0, count: width)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let value = max(rgba[i], rgba[i + 1], rgba[i + 2])
                rowBrightness[y] += Int(value)
                columnBrightness[x] += Int(value)
                if value > litLevel {
                    rowLit[y] += 1
                    columnLit[x] += 1
                }
            }
        }
        let rows = rowLit.indices.filter { Double(rowLit[$0]) > litShare * Double(width) }
        let columns = columnLit.indices.filter { Double(columnLit[$0]) > litShare * Double(height) }
        guard let firstRow = rows.first, let lastRow = rows.last, let firstColumn = columns.first, let lastColumn = columns.last
        else { return nil }
        func unsmeared(_ first: Int, _ last: Int, _ brightness: [Int]) -> (Int, Int) {
            var (a, b) = (first, last)
            for _ in 0..<smearLines where b - a > 2 && brightness[a] * 2 < brightness[a + 1] { a += 1 }
            for _ in 0..<smearLines where b - a > 2 && brightness[b] * 2 < brightness[b - 1] { b -= 1 }
            return (a, b)
        }
        let (top, bottom) = unsmeared(firstRow, lastRow, rowBrightness)
        let (left, right) = unsmeared(firstColumn, lastColumn, columnBrightness)
        let w = Double(width), h = Double(height)
        let rect = CGRect(x: Double(left) / w, y: Double(height - 1 - bottom) / h,
                          width: Double(right - left + 1) / w, height: Double(bottom - top + 1) / h)
        return rect.width >= minimumContent && rect.height >= minimumContent ? rect : nil
    }

    /// The box around the picture over several frames (nil frames were too dark); nil when there are no bars.
    public static func combine(_ rects: [CGRect?]) -> CGRect? {
        guard var box = rects.compactMap({ $0 }).first else { return nil }
        for rect in rects.compactMap({ $0 }) { box = box.union(rect) }
        let minX = box.minX < minimumBar ? 0 : box.minX, maxX = 1 - box.maxX < minimumBar ? 1 : box.maxX
        let minY = box.minY < minimumBar ? 0 : box.minY, maxY = 1 - box.maxY < minimumBar ? 1 : box.maxY
        let snapped = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return snapped == CGRect(x: 0, y: 0, width: 1, height: 1) ? nil : snapped
    }

    /// The lit box of an upright SDR picture (extent origin at 0, 0). Rows are measured on the picture narrowed to
    /// `sampleSize` columns and columns on it flattened to `sampleSize` rows: each edge keeps its full resolution.
    public static func contentRect(of image: CIImage, context: CIContext) -> CGRect? {
        let full = image.extent.size
        func measure(_ size: CGSize) -> CGRect? {
            let small = size == full ? image : ImageScaling.lanczos(image, to: size)
            let width = Int(size.width), height = Int(size.height)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            context.render(small, toBitmap: &pixels, rowBytes: width * 4, bounds: CGRect(origin: .zero, size: size),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return contentRect(rgba: pixels, width: width, height: height)
        }
        let side = CGFloat(sampleSize)
        guard let rows = measure(CGSize(width: min(full.width, side), height: full.height)),
              let columns = measure(CGSize(width: full.width, height: min(full.height, side))) else { return nil }
        return CGRect(x: columns.minX, y: rows.minY, width: columns.width, height: rows.height)
    }
}

/// Black-bar detection for one file (aspect spec): its own decoder reads keyframes spread over the file, and the
/// box around the picture in all of them is the crop. Runs once, in the background.
public final class CropSampler: @unchecked Sendable {
    private let url: URL
    private let index: FrameIndex
    private let rotation: Int
    private let readCache: ReadCache?
    private let cancelled = CancellationFlag()

    public init(url: URL, index: FrameIndex, rotationClockwise: Int, readCache: ReadCache? = nil) {
        self.url = url
        self.index = index
        rotation = rotationClockwise
        self.readCache = readCache
    }

    /// Calls `completion` on the main queue with the crop (nil: no bars, or the file could not be sampled),
    /// unless cancelled first.
    public func start(samples: Int = 10, completion: @escaping @Sendable (CGRect?) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let crop = detect(samples: samples)
            DispatchQueue.main.async { [self] in
                if !cancelled.isCancelled { completion(crop) }
            }
        }
    }

    public func cancel() { cancelled.cancel() }

    func detect(samples: Int) -> CGRect? {
        guard index.frameCount > 0,
              let decoder = try? VideoDecoder(source: MediaSource(url: url, readCache: readCache), index: index) else { return nil }
        let context = CIContext(options: [.cacheIntermediates: false])
        var seen = Set<Int64>()
        var rects: [CGRect?] = []
        for i in 0..<samples {
            if cancelled.isCancelled { break }
            let fraction = samples > 1 ? 0.05 + 0.9 * Double(i) / Double(samples - 1) : 0.5
            let target = Int(fraction * Double(index.frameCount - 1))
            // A pool per sample: the Core Image objects hold the decoded frame (an IOSurface of VTDecoderXPCService).
            autoreleasepool {
                guard (try? decoder.seekToKeyframe(near: target)) != nil,
                      let frame = (try? decoder.nextFrame()) ?? nil, seen.insert(frame.pts).inserted else { return }
                let image = FrameImageRenderer.image(for: frame, rotationClockwise: rotation, toneMapToSDR: true)
                rects.append(BlackBars.contentRect(of: image, context: context))
            }
        }
        return BlackBars.combine(rects)
    }
}
