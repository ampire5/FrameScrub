import CoreImage
import CoreImage.CIFilterBuiltins

/// The parts of the automatic adjustments that can be turned off one by one (`auto-color-filters`).
public enum AutoColorFilter: String, CaseIterable, Sendable {
    case curve, shadows, vibrance

    init?(filterName: String) {
        switch filterName {
        case "CIToneCurve": self = .curve
        case "CIHighlightShadowAdjust": self = .shadows
        case "CIVibrance": self = .vibrance
        default: return nil
        }
    }
}

/// When the automatic adjustments are computed again (`auto-color-interval`).
public enum AutoColorSchedule {
    /// Whether the frame at `seconds` needs fresh adjustments: it is at least `interval` seconds of video away
    /// from the frame they were computed from (playing on, or a jump). `analysedAt` is nil while auto colour is off.
    public static func isDue(interval: Double, analysedAt: Double?, seconds: Double) -> Bool {
        guard interval > 0, let analysedAt else { return false }
        return abs(seconds - analysedAt) >= interval
    }

    /// Whether a scene gets the automatic correction: it changes the picture by at least `threshold`
    /// (`auto-color-threshold`, mean difference 0…255); 0 corrects every scene.
    public static func isNeeded(delta: Double, threshold: Double) -> Bool {
        threshold <= 0 || delta >= threshold
    }

    /// The share of `auto-color-strength` a scene gets: 0 at the threshold, growing in a line to the whole strength
    /// at `full` (`auto-color-full`), so scenes that barely need it are barely touched. `full` at or below the
    /// threshold gives the whole strength to every scene that needs it.
    public static func rampStrength(delta: Double, threshold: Double, full: Double) -> Double {
        guard isNeeded(delta: delta, threshold: threshold) else { return 0 }
        guard full > threshold else { return 1 }
        return min(1, max(0, (delta - threshold) / (full - threshold)))
    }
}

/// What the analysis of one frame found: the steps, and how much they change that frame when applied in full.
public struct AutoColorAnalysis: @unchecked Sendable {   // parameter values are immutable NSNumber/CIVector
    public let steps: [ColorCorrection.Step]
    /// Mean absolute difference over R, G and B (sRGB, 0…255) the full correction makes to the frame.
    public let delta: Double
}

/// Colour correction for the screen (backlog §6): automatic adjustments computed once from a still frame,
/// then vibrance. Saved frames get it only with `save-color=yes`.
public struct ColorCorrection: @unchecked Sendable {   // parameter values are immutable NSNumber/CIVector
    /// One Core Image filter with its parameters, without the input image.
    public struct Step {
        public let name: String
        public let kind: AutoColorFilter
        let parameters: [String: Any]
    }

    public static let identity = ColorCorrection()

    /// `CIVibrance.amount`, 0…1; 0 is off.
    public var vibrance: Double
    /// Filters from `autoAdjustment(for:)`; empty is off.
    public var auto: [Step]
    /// 0…1: how much of the automatic adjustments is mixed into the picture.
    public var autoStrength: Double
    /// Which of `auto` are applied.
    public var autoFilters: Set<AutoColorFilter>
    /// Multiplies the vibrance the analysis chose (Apple picks about 0.06…0.15).
    public var autoVibranceGain: Double

    public init(vibrance: Double = 0, auto: [Step] = [], autoStrength: Double = 1,
                autoFilters: Set<AutoColorFilter> = Set(AutoColorFilter.allCases), autoVibranceGain: Double = 1) {
        self.vibrance = vibrance
        self.auto = auto
        self.autoStrength = autoStrength
        self.autoFilters = autoFilters
        self.autoVibranceGain = autoVibranceGain
    }

    /// The amount of the automatic vibrance after `autoVibranceGain`, capped at 1; nil when it is not applied.
    public var autoVibrance: Double? {
        guard let step = activeAuto.first(where: { $0.kind == .vibrance }),
              let amount = (step.parameters[kCIInputAmountKey] as? NSNumber)?.doubleValue else { return nil }
        return min(1, amount * autoVibranceGain)
    }

    /// The automatic steps that take effect.
    public var activeAuto: [Step] { autoStrength > 0 ? auto.filter { autoFilters.contains($0.kind) } : [] }

    public var isIdentity: Bool { vibrance <= 0 && activeAuto.isEmpty }

    /// The corrected image with the same extent; the image itself when there is nothing to do.
    public func apply(to image: CIImage) -> CIImage {
        guard !isIdentity else { return image }
        var result = image
        let steps = activeAuto
        for step in steps {
            guard let filter = CIFilter(name: step.name) else { continue }
            filter.setValuesForKeys(step.parameters)
            if step.kind == .vibrance, let amount = autoVibrance { filter.setValue(amount, forKey: kCIInputAmountKey) }
            filter.setValue(result, forKey: kCIInputImageKey)
            result = filter.outputImage ?? result
        }
        if !steps.isEmpty, autoStrength < 1 {
            let mix = CIFilter.dissolveTransition()
            mix.inputImage = image
            mix.targetImage = result
            mix.time = Float(autoStrength)
            result = mix.outputImage ?? result
        }
        if vibrance > 0 {
            let filter = CIFilter.vibrance()
            filter.inputImage = result
            filter.amount = Float(min(vibrance, 1))
            result = filter.outputImage ?? result
        }
        return result.cropped(to: image.extent)
    }

    /// `image` corrected partway (`progress` 0…1) from `old` to `new`, so a recomputed correction fades in.
    public static func transition(from old: ColorCorrection, to new: ColorCorrection, progress: Double,
                                  image: CIImage) -> CIImage {
        if progress <= 0 { return old.apply(to: image) }
        if progress >= 1 { return new.apply(to: image) }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = old.apply(to: image)
        mix.targetImage = new.apply(to: image)
        mix.time = Float(progress)
        return mix.outputImage?.cropped(to: image.extent) ?? new.apply(to: image)
    }

    /// The stats line (`i`): what is applied on screen and whether saved files get it.
    /// `autoPending`: auto colour is on but no frame has been analysed yet.
    /// `autoDelta`: how much the full correction changes the analysed frame; with `auto` empty, the scene needs none.
    /// `origin`: where the file's colour settings came from, marked ` · file` / ` · folder` at the end (colour memory §6).
    public func statusText(autoFrame: Int?, autoPending: Bool = false, interval: Double = 0, autoDelta: Double? = nil,
                           saved: Bool, origin: ColorOrigin = .default) -> String {
        var parts: [String] = []
        if vibrance > 0 { parts.append("vibrance \(formatNumber(vibrance))") }
        let every = interval > 0 ? " every \(formatNumber(interval)) s" : ""
        if autoPending, autoFrame == nil, auto.isEmpty {
            parts.append("auto waiting for a picture")
        } else if let autoFrame, auto.isEmpty, let autoDelta {
            parts.append("auto from frame \(autoFrame)\(every): Δ \(String(format: "%.1f", autoDelta)), needs none")
        } else if autoFrame != nil || !auto.isEmpty {
            let kinds = AutoColorFilter.allCases.filter { kind in activeAuto.contains { $0.kind == kind } }.map { kind in
                kind == .vibrance ? autoVibrance.map { String(format: "vibrance %.2f", $0) } ?? "vibrance" : kind.rawValue
            }
            parts.append("auto \(formatNumber(autoStrength))" + (autoFrame.map { " from frame \($0)" } ?? "") + every
                         + (autoDelta.map { String(format: ", Δ %.1f", $0) } ?? "")
                         + " (\(kinds.isEmpty ? (auto.isEmpty ? "nothing to correct" : "nothing chosen") : kinds.joined(separator: ", ")))")
        }
        let mark = switch origin {
        case .default: ""
        case .folder: " · folder"
        case .file: " · file"
        }
        guard !parts.isEmpty else { return "Colour: off" + mark }
        return "Colour: " + parts.joined(separator: ", ") + (saved ? ", files with it" : ", files without it") + mark
    }

    private static let analysisContext = CIContext(options: [.cacheIntermediates: false])

    /// A nearly black frame (a fade-in, a title on black): Apple's analysis of it stretches the tones wildly,
    /// so auto colour that starts by itself waits for a frame with a picture.
    public static func isTooDarkToAnalyse(_ image: CIImage) -> Bool {
        let average = CIFilter.areaAverage()
        average.inputImage = image
        average.extent = image.extent
        guard let output = average.outputImage else { return false }
        var pixel = [Float](repeating: 0, count: 4)
        analysisContext.render(output, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                               format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))   // as seen, not linear
        return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2] < 0.06
    }

    /// Apple's automatic adjustments (vibrance, tone curve, shadows and highlights) for `image`, kept as
    /// parameters so they can be applied to later frames. Face balance and red-eye are left out: they
    /// would shift skin tones from one analysed frame onto every other one.
    public static func autoAdjustment(for image: CIImage) -> [Step] {
        analyse(image).steps
    }

    /// The automatic adjustments for `image` and how much they change it in full (strength 1, all parts,
    /// vibrance gain 1), which decides whether the scene needs them (`auto-color-threshold`).
    public static func analyse(_ image: CIImage) -> AutoColorAnalysis {
        // Statistics only: a smaller copy is enough and keeps the analysis quick on 4K frames.
        let longest = max(image.extent.width, image.extent.height)
        let sample = longest > 1024 ? ImageScaling.lanczos(image, scale: 1024 / longest) : image
        let steps = adjustmentSteps(for: sample)
        return AutoColorAnalysis(steps: steps, delta: meanDifference(sample, ColorCorrection(auto: steps).apply(to: sample)))
    }

    /// Mean absolute difference over R, G and B between two images of the same extent, as seen (sRGB, 0…255).
    private static func meanDifference(_ a: CIImage, _ b: CIImage) -> Double {
        let width = Int(a.extent.width), height = Int(a.extent.height)
        guard width > 0, height > 0 else { return 0 }
        func pixels(_ image: CIImage) -> [UInt8] {
            var buffer = [UInt8](repeating: 0, count: width * height * 4)
            analysisContext.render(image, toBitmap: &buffer, rowBytes: width * 4, bounds: a.extent, format: .RGBA8,
                                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
            return buffer
        }
        let before = pixels(a), after = pixels(b)
        var sum = 0
        for i in stride(from: 0, to: before.count, by: 4) {
            sum += abs(Int(before[i]) - Int(after[i])) + abs(Int(before[i + 1]) - Int(after[i + 1])) + abs(Int(before[i + 2]) - Int(after[i + 2]))
        }
        return Double(sum) / Double(width * height * 3)
    }

    private static func adjustmentSteps(for sample: CIImage) -> [Step] {
        let filters = sample.autoAdjustmentFilters(options: [.redEye: false, .enhance: true])
        return filters.compactMap { filter in
            guard let kind = AutoColorFilter(filterName: filter.name) else { return nil }   // face balance, red-eye
            var parameters: [String: Any] = [:]
            for key in filter.inputKeys where key != kCIInputImageKey {
                if let value = filter.value(forKey: key) { parameters[key] = value }
            }
            return Step(name: filter.name, kind: kind, parameters: parameters)
        }
    }
}
