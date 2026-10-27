import CoreImage
import CoreML
import Foundation
import os
import Vision

// Subject Focus (spike/subject-mask): the background around the people darkened, blurred or greyed while the people stay
// as they are. Vision's person segmentation makes the mask (on the neural engine), Core Image applies the effect in the
// frame's own pixels before scaling. Ported from the PersonVideo prototype (scratchpad), where the numbers come from:
// M4 Max, Vision balanced 9.6 ms a 1080p frame on the ANE (14.6 on the GPU), accurate 34 ms.

/// The looks, in `H`'s order. Brightness −1 … +1 reaches pure black / white; blur 0…1 (sigma ∝ blur²); falloff: less
/// effect close to the people, full far away.
enum SubjectFocusStyle: String, CaseIterable {
    case studio, lens, black, white, accent

    var title: String {
        switch self {
        case .studio: "Studio"
        case .lens: "Lens"
        case .black: "Black"
        case .white: "White"
        case .accent: "Accent"
        }
    }

    struct Look { var brightness = 0.0, desaturate = 0.0, blur = 0.0, falloff = 0.0 }

    var look: Look {
        switch self {
        case .studio: Look(brightness: -0.45, desaturate: 0.6, blur: 0.35, falloff: 0.2)
        case .lens: Look(blur: 0.75, falloff: 0.3)
        case .black: Look(brightness: -1)
        case .white: Look(brightness: 1)
        case .accent: Look(brightness: -0.2, desaturate: 1, blur: 0.15)
        }
    }

    var next: SubjectFocusStyle {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// One mask: 8-bit, at Vision's own size (balanced ~512 wide, accurate kept ≤ 1024), stretched over the whole frame.
struct SubjectMask {
    let image: CIImage
    let frame: Int
    let accurate: Bool
    /// Playback masks: the mean change of the mask against the previous frame's (of 255), the flicker on a still scene.
    var change: Double? = nil
    /// RVM's alpha matte (`SubjectMatting`): soft already, refined along the picture's own edges instead of eroded and
    /// feathered.
    var matte = false
}

/// Makes the masks off the main thread, one at a time: a frame that comes while one is being made waits in a single
/// slot, replaced by any newer one (so a slow mask skips frames rather than queueing them). Playback frames get
/// Vision's balanced quality with temporal smoothing; a still frame (`accurate`) gets the accurate quality on its own.
/// Main thread: `submit`, `reset`; the results come back on main.
final class SubjectMasker: @unchecked Sendable {
    struct Job {
        let pixelBuffer: CVPixelBuffer
        let image: CIImage?             // the upright picture, when the frame is turned (Vision then takes the image)
        let frame: Int
        let accurate: Bool
        var rvm = false                 // RVM's matte (when its models are there), else Vision's mask
        var mainPeople = false          // only the big people (`SubjectSelection`)
    }

    var onMask: ((SubjectMask, _ visionMs: Double) -> Void)?
    private let queue = DispatchQueue(label: "subject-focus.mask", qos: .userInitiated)
    private var busy = false            // main
    private var waiting: Job?           // main: the one slot
    private var generation = 0          // main: `reset` drops results of before

    // queue only
    private let balanced = VNGeneratePersonSegmentationRequest()
    private let accurate = VNGeneratePersonSegmentationRequest()
    private let sequence = VNSequenceRequestHandler()
    private var smooth: [Float] = []
    private var state: [Bool] = []
    private var size = (0, 0)
    private var lastFrame = Int.min
    private var previous: [UInt8] = []
    private var previousLuma: [UInt8] = []
    private let matting = SubjectMatting()
    private var selection = SubjectSelection()
    /// The picture's own change (of 255) taken as motion, when the frame's luma can be read: a mask change where the
    /// picture stands still is flicker and is smoothed hard (`stillKeep`); where the picture moved it follows at once.
    private static let lumaMotion: Float = 10, stillKeep: Float = 0.85

    /// Benches (spike): `FRAMESCRUB_FOCUS_QUALITY=fast|balanced|accurate`, the playback masks' Vision quality (balanced
    /// by default); `FRAMESCRUB_FOCUS_SMOOTH=0` shows Vision's raw masks (no smoothing, no hysteresis).
    private static let liveQuality: VNGeneratePersonSegmentationRequest.QualityLevel = {
        switch ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_QUALITY"] {
        case "fast": .fast
        case "accurate": .accurate
        default: .balanced
        }
    }()
    private static let smoothing = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_SMOOTH"] != "0"

    /// How much of the past a quiet pixel keeps, and the change (of 255) taken as motion at once (no ghost behind a
    /// moving person): the prototype's live values (flicker 0.129 → 0.025 with the hysteresis, static 1080p clip).
    private static let keep: Float = 0.5, motion: Float = 48

    init() {
        for (request, quality) in [(balanced, Self.liveQuality), (accurate, .accurate)] {
            request.qualityLevel = quality
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            // The neural engine: 3× faster than the GPU for balanced here, and it leaves the GPU to the picture.
            if let ane = MLModel.availableComputeDevices.first(where: { if case .neuralEngine = $0 { true } else { false } }) {
                request.setComputeDevice(ane, for: .main)
            }
        }
    }

    func submit(_ job: Job) {
        if busy { waiting = job; return }
        start(job)
    }

    /// Off, or another file: nothing in flight is shown, the smoothing starts over.
    func reset() {
        generation += 1
        waiting = nil
        queue.async { [self] in smooth = []; lastFrame = .min; matting.reset(); selection.reset() }
    }

    private func start(_ job: Job) {
        busy = true
        let generation = generation
        queue.async { [self] in
            let started = DispatchTime.now().uptimeNanoseconds
            let mask = autoreleasepool { make(job) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
            DispatchQueue.main.async { [self] in
                busy = false
                if generation == self.generation, let mask { onMask?(mask, ms) }
                if let next = waiting {
                    waiting = nil
                    start(next)
                }
            }
        }
    }

    /// The frame's luma at `w`×`h` (nearest sample of an 8-bit Y plane), nil for other formats.
    private static func luma(_ pb: CVPixelBuffer, _ w: Int, _ h: Int) -> [UInt8]? {
        let format = CVPixelBufferGetPixelFormatType(pb)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return nil }
        let pw = CVPixelBufferGetWidthOfPlane(pb, 0), ph = CVPixelBufferGetHeightOfPlane(pb, 0)
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            let row = (base + min(ph - 1, (y * ph + ph / (2 * h)) / h) * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w { out[y * w + x] = row[min(pw - 1, (x * pw + pw / (2 * w)) / w)] }
        }
        return out
    }

    private func make(_ job: Job) -> SubjectMask? {
        if job.rvm, let mask = makeMatte(job) { return mask }
        let request = job.accurate ? accurate : balanced
        do {
            if let image = job.image {
                try sequence.perform([request], on: image)
            } else {
                try sequence.perform([request], on: job.pixelBuffer)
            }
        } catch { return nil }
        guard let pb = request.results?.first?.pixelBuffer else { return nil }
        let mw = CVPixelBufferGetWidth(pb), mh = CVPixelBufferGetHeight(pb)
        // accurate masks (~2016×1512) kept ≤ 1024 wide: the edge is feathered anyway, and the loops below stay ~1 ms
        let factor = max(1, (mw + 1023) / 1024)
        let w = mw / factor, h = mh / factor
        var raw = [UInt8](repeating: 0, count: w * h)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let base = CVPixelBufferGetBaseAddress(pb)!, rowBytes = CVPixelBufferGetBytesPerRow(pb)
        for y in 0..<h {
            for x in 0..<w {
                var sum = 0
                for dy in 0..<factor {
                    let row = (base + (y * factor + dy) * rowBytes).assumingMemoryBound(to: UInt8.self)
                    for dx in 0..<factor { sum += Int(row[x * factor + dx]) }
                }
                raw[y * w + x] = UInt8(sum / (factor * factor))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)

        let luma = job.image == nil ? Self.luma(job.pixelBuffer, w, h) : nil
        // Playback: motion-adaptive smoothing over time, then hysteresis (on above 0.6, off below 0.4). A still frame:
        // its own accurate mask, only stretched. A jump (seek, loop) or another size starts the smoothing over.
        let continuous = !job.accurate && size == (w, h) && !smooth.isEmpty && lastFrame != .min
            && abs(job.frame - lastFrame) <= 4   // a few skipped frames still count; a seek does not
        if !job.accurate {
            if !continuous {
                smooth = raw.map(Float.init)
                state = smooth.map { $0 >= 127.5 }
                size = (w, h)
            }
            lastFrame = job.frame
        }
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            let ob = o.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) {
                var v: Float
                if job.accurate || !Self.smoothing {
                    v = Float(raw[i]) / 255
                } else {
                    let n = Float(raw[i]), s = smooth[i]
                    let k: Float
                    if !continuous {
                        k = 0
                    } else if let luma, previousLuma.count == luma.count {
                        k = Self.stillKeep * max(0, 1 - abs(Float(luma[i]) - Float(previousLuma[i])) / Self.lumaMotion)
                    } else {
                        k = Self.keep * max(0, 1 - abs(n - s) / Self.motion)
                    }
                    let e = s * k + n * (1 - k)
                    smooth[i] = e
                    v = e / 255
                    if v > 0.6 { state[i] = true } else if v < 0.4 { state[i] = false }
                }
                // stretched a little (0.2…0.8 → 0…1): firmer, still soft enough that a small grid shows no steps
                let x = min(1, max(0, (v - 0.2) / 0.6)), c = x * x * (3 - 2 * x)
                let o = job.accurate || !Self.smoothing || v < 0.4 || v > 0.6 ? c : (state[i] ? max(c, 0.5) : min(c, 0.5))
                ob[i] = UInt8(o * 255 + 0.5)
            }
        }
        if job.mainPeople { out = select(out, w, h, job: job, continuous: continuous) }
        let image = CIImage(bitmapData: out, bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
        if !job.accurate, let luma { previousLuma = luma }
        var change: Double?
        if !job.accurate {
            let bytes = [UInt8](out)
            if continuous, previous.count == bytes.count {
                var sum = 0
                for i in 0..<bytes.count { sum += abs(Int(bytes[i]) - Int(previous[i])) }
                change = Double(sum) / Double(bytes.count)
            }
            previous = bytes
        }
        return SubjectMask(image: image, frame: job.frame, accurate: job.accurate, change: change)
    }
}

extension SubjectMasker {
    /// Only the main people of `bytes`: playback carries the choice from frame to frame, a still frame chooses afresh.
    fileprivate func select(_ bytes: Data, _ w: Int, _ h: Int, job: Job, continuous: Bool) -> Data {
        var mask = [UInt8](bytes)
        if job.accurate {
            var still = SubjectSelection()
            still.apply(&mask, w, h, continuous: false)
        } else {
            selection.apply(&mask, w, h, continuous: continuous)
        }
        return Data(mask)
    }

    /// RVM's matte for `job`: its state carries over while the frames follow each other (a few skipped still count).
    fileprivate func makeMatte(_ job: Job) -> SubjectMask? {
        let continuous = lastFrame != .min && abs(job.frame - lastFrame) <= 4
        let picture = job.image ?? CIImage(cvPixelBuffer: job.pixelBuffer)
        guard var (bytes, w, h) = matting.alpha(of: picture, still: job.accurate, continuous: continuous) else { return nil }
        if job.mainPeople { bytes = select(bytes, w, h, job: job, continuous: continuous) }
        if !job.accurate { lastFrame = job.frame }
        var change: Double?
        if !job.accurate {
            let b = [UInt8](bytes)
            if continuous, previous.count == b.count {
                var sum = 0
                for i in 0..<b.count { sum += abs(Int(b[i]) - Int(previous[i])) }
                change = Double(sum) / Double(b.count)
            }
            previous = b
        }
        let image = CIImage(bitmapData: bytes, bytesPerRow: w, size: CGSize(width: w, height: h), format: .L8, colorSpace: nil)
        return SubjectMask(image: image, frame: job.frame, accurate: job.accurate, change: change, matte: true)
    }
}

/// The effect: `image` (the upright frame, any extent) with its background changed by `look`, `amount` 0…1 of it
/// (the fades). Core Image only; the costly parts (blur, colour carried over the edge) work at a quarter of the frame.
enum SubjectFocusEffect {
    private static let divide = CIColorKernel(source: """
    kernel vec4 divideByWeight(__sample a, __sample w) { float d = max(w.r, 0.0005); return vec4(a.rgb / d, 1.0); }
    """)!

    // Fast guided filter (He & Sun 2015) for RVM's matte: on the matte's own grid each window fits the matte as a
    // linear function of the picture's luma (a·I + b); a and b, smoothed and scaled up, are applied to the full-size luma,
    // so the edge follows the picture's edges at full resolution for the cost of the small grid.
    private static let guidePack = CIColorKernel(source: """
    kernel vec4 guidePack(__sample c, __sample m) {
        float i = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)); float p = m.r;
        return vec4(i, p, i * p, i * i);
    }
    """)!
    private static let guideCoefficients = CIColorKernel(source: """
    kernel vec4 guideCoefficients(__sample s, float eps) {
        float a = (s.b - s.r * s.g) / (s.a - s.r * s.r + eps);
        return vec4(a, s.g - a * s.r, 0.0, 1.0);
    }
    """)!
    private static let guideApply = CIColorKernel(source: """
    kernel vec4 guideApply(__sample ab, __sample c) {
        float q = clamp(ab.r * dot(c.rgb, vec3(0.2126, 0.7152, 0.0722)) + ab.g, 0.0, 1.0);
        return vec4(q, q, q, 1.0);
    }
    """)!
    /// Window radius on the matte's grid (2 of 512 px: ~8 px of a 1080p frame) and the regulariser: a smaller one
    /// follows weaker edges of the picture (and its noise).
    private static let guideRadius = 2.0, guideEps = 0.0004
    /// Benches: `FRAMESCRUB_FOCUS_REFINE=0` shows RVM's matte only scaled up.
    private static let refines = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_REFINE"] != "0"

    /// RVM's small `matte` refined along the edges of `image` (the frame it was made of), at the frame's size.
    static func refined(_ matte: CIImage, guide image: CIImage) -> CIImage {
        let ext = image.extent, small = matte.extent
        let sx = small.width / ext.width, sy = small.height / ext.height
        let guideSmall = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: sy, kCIInputAspectRatioKey: sx / sy])
        let g = guideSmall.transformed(by: .init(translationX: small.minX - guideSmall.extent.minX, y: small.minY - guideSmall.extent.minY))
            .cropped(to: small)
        func box(_ i: CIImage) -> CIImage {
            i.clampedToExtent().applyingFilter("CIBoxBlur", parameters: [kCIInputRadiusKey: guideRadius]).cropped(to: small)
        }
        let stats = box(guidePack.apply(extent: small, arguments: [g, matte])!)
        let ab = box(guideCoefficients.apply(extent: small, arguments: [stats, guideEps])!)
        let up = ab.clampedToExtent()
            .transformed(by: .init(translationX: -small.minX, y: -small.minY))
            .transformed(by: .init(scaleX: 1 / sx, y: 1 / sy))
            .transformed(by: .init(translationX: ext.minX, y: ext.minY)).cropped(to: ext)
        return guideApply.apply(extent: ext, arguments: [up, image])!
    }

    private static func scaled(_ img: CIImage, by f: Double, bias: Double = 0) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: f, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: f, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: f, w: 0), "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)])
    }

    static func apply(to image: CIImage, mask raw: CIImage, matte: Bool = false, look: SubjectFocusStyle.Look,
                      amount: Double) -> CIImage {
        let ext = image.extent
        guard amount > 0, ext.width >= 8, ext.height >= 8 else { return image }
        let toFrame = CGAffineTransform(scaleX: ext.width / raw.extent.width, y: ext.height / raw.extent.height)
            .concatenating(.init(translationX: ext.minX, y: ext.minY))
        // feathered, the edge pulled in a little, on the small mask; then scaled to the frame
        let sigma = 0.3 * raw.extent.width * 0.008
        let m = matte && refines ? refined(raw, guide: image) : matte ? raw.transformed(by: toFrame).cropped(to: ext) : raw.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: sigma * 1.5])
            .applyingGaussianBlur(sigma: sigma)
            .transformed(by: toFrame).cropped(to: ext)
        // w: how much of the effect a pixel gets (1 − mask), less near the people with falloff, times the fade
        var w = m.applyingFilter("CIColorInvert")
        if look.falloff > 0 {
            let near = raw.clampedToExtent().applyingGaussianBlur(sigma: raw.extent.width * 0.06).transformed(by: toFrame).cropped(to: ext)
            w = w.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: scaled(near, by: -look.falloff, bias: 1)])
        }
        if amount < 1 { w = scaled(w, by: amount).cropped(to: ext) }

        let q: CGFloat = 0.25
        let sr = ext.applying(.init(scaleX: q, y: q))
        func quarter(_ i: CIImage) -> CIImage { i.transformed(by: .init(scaleX: q, y: q)).cropped(to: sr) }
        func normalizedBlur(_ i: CIImage, weight: CIImage, sigma: Double) -> CIImage {
            // blur(image·w) / blur(w): the people's colours do not halo into the background, nor the reverse
            let pre = i.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .black).cropped(to: sr), kCIInputMaskImageKey: weight])
            let a = pre.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: sr)
            let b = weight.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: sr)
            return divide.apply(extent: sr, arguments: [a, b])!
                .clampedToExtent().transformed(by: .init(scaleX: 1 / q, y: 1 / q)).cropped(to: ext)
        }

        var bg = image
        if look.blur > 0 {
            bg = normalizedBlur(quarter(image), weight: quarter(m.applyingFilter("CIColorInvert")),
                                sigma: max(0.5, look.blur * look.blur * sr.width * 0.06))
        }
        if look.desaturate > 0 { bg = bg.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 - look.desaturate]) }
        if look.brightness != 0 {
            // ±1 reaches pure black / white: c·f, or 1 − (1 − c)·f, in linear light
            let f = pow(1 - min(1, abs(look.brightness)), 2.2)
            bg = scaled(bg, by: f, bias: look.brightness < 0 ? 0 : 1 - f).cropped(to: ext)
        }
        // the edge band takes the person's own colours carried outwards: no rim of the old background around the hair
        let core = raw.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: max(1.5, raw.extent.width * 0.004)])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 3]).applyingFilter("CIColorClamp")
            .transformed(by: toFrame).cropped(to: ext)
        let carried = normalizedBlur(quarter(image), weight: quarter(core), sigma: max(1, sr.width * 0.005))
        // only under the mask: where it is 0 the frame stays itself (the fades and falloff mix the background with it)
        let person = image.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: carried, kCIInputMaskImageKey: core])
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: m])
        return bg.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: person, kCIInputMaskImageKey: w])
            .cropped(to: ext)
    }
}
