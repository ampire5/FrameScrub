import CoreImage
import CoreML
import Foundation
import os

/// RobustVideoMatting (spike, optional): an alpha matte of the people that remembers the frames before (a recurrent
/// network), so it holds still where Vision's per-frame masks flicker. The models are not shipped: the user prepares them
/// (scripts/rvm/prepare-models.sh, docs/subject-focus-rvm.md) into `directory`; without them Subject Focus uses Vision.
///
/// Measured (M4 Max, 1080p runway clip, flicker after motion compensation, of 255): Vision balanced + smoothing 1.36,
/// RVM MobileNetV3 at 512×288 0.80, 3.5 ms a frame on the neural engine (263 of 265 ops; the GPU stays with the picture).
/// Queue only (SubjectMasker's queue).
final class SubjectMatting {
    static let directory: URL = {
        if let dir = ProcessInfo.processInfo.environment["FRAMESCRUB_RVM_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RobustVideoMatting")
    }()

    /// Playback: the frame scaled to 512×288 (portrait 288×512); a still frame: 768×432, `stillPasses` passes of the
    /// same frame from a fresh state (the state settles in 4–6, change per pass ≤ 0.2/255 on photos).
    private static let live = (512, 288), still = (768, 432)
    private static let stillPasses = 4
    /// Scrubbing (paused, the wheel stepping frames): the still frame's 768×432 model with the state carried from step to
    /// step, and `scrubJumpPasses` passes after a jump. Measured (rvmscrub, scratchpad; runway 1080p, M4 Max), the error
    /// against the pause's mask (of 255) and the time a step: ±1 frame 512 0.70 → 768 0.32 (4.3 → 6.7 ms); fast ×8
    /// 512 fresh 1.49, 768 fresh 1 pass 0.88, 2 passes 0.57 (12 ms), 3 passes 0.35 (18 ms, past the 20 ms a frame
    /// waits for its mask); carrying the state over a jump instead: 0.96.
    private static let scrubJumpPasses = 2

    /// Whether the models are there (checked once per launch; the menu greys Mask: RVM without them).
    static let isAvailable: Bool = {
        [live, still].allSatisfy { size in
            [(size.0, size.1), (size.1, size.0)].allSatisfy { url(for: $0).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        }
    }()

    private static func url(for size: (Int, Int)) -> URL? {
        directory.appendingPathComponent("rvm_mnv3_\(size.0)x\(size.1).mlpackage")
    }

    private struct Loaded {
        let model: MLModel
        let width: Int, height: Int
        let input: CVPixelBuffer
    }

    private var models: [String: Loaded] = [:]
    private var state: [String: MLFeatureValue] = [:]
    private var stateModel = ""
    /// The previous playback frame's luma on a coarse grid, to see a cut.
    private var signature: [UInt8] = []
    /// A cut: the coarse luma changed by more than this on average (of 255). Measured (`FRAMESCRUB_FOCUS_LOG=1`): a
    /// runway's walking, zooms and pans up to 12.1, hard cuts between scenes 28.5, 48.4 and 60.8.
    private static let cutThreshold = 20.0
    private static let cutLog = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_LOG"] == "1"
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                              .name: "subject-matting"])
    private let log = Logger(subsystem: "FrameScrub", category: "subject-matting")

    /// The compiled model, compiled from the user's .mlpackage once and kept in Caches (by the package's date).
    private func load(_ size: (Int, Int)) -> Loaded? {
        let key = "\(size.0)x\(size.1)"
        if let m = models[key] { return m }
        guard let package = Self.url(for: size) else { return nil }
        do {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FrameScrub/RVM", isDirectory: true)
            let stamp = (try? package.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                .map { Int($0.timeIntervalSince1970) } ?? 0
            let compiled = caches.appendingPathComponent("rvm_mnv3_\(key)-\(stamp).mlmodelc")
            if !FileManager.default.fileExists(atPath: compiled.path) {
                try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
                let temp = try MLModel.compileModel(at: package)
                try? FileManager.default.removeItem(at: compiled)
                try FileManager.default.moveItem(at: temp, to: compiled)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: config)
            var input: CVPixelBuffer?
            CVPixelBufferCreate(nil, size.0, size.1, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &input)
            let loaded = Loaded(model: model, width: size.0, height: size.1, input: input!)
            models[key] = loaded
            return loaded
        } catch {
            log.error("RVM model \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func freshState(_ m: Loaded) -> [String: MLFeatureValue] {
        var s: [String: MLFeatureValue] = [:]
        for i in 1...4 {
            guard let d = m.model.modelDescription.inputDescriptionsByName["r\(i)i"]?.multiArrayConstraint,
                  let a = try? MLMultiArray(shape: d.shape, dataType: .float16) else { continue }
            memset(a.dataPointer, 0, a.count * 2)
            s["r\(i)i"] = MLFeatureValue(multiArray: a)
        }
        return s
    }

    /// Forgets the frames before: a seek, another file, a still frame's own passes.
    func reset() {
        state = [:]
        stateModel = ""
        signature = []
    }

    /// The model input's luma on a 32×18 grid (a sample each, the input is already small).
    private static func signature(of pb: CVPixelBuffer) -> [UInt8] {
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), rb = CVPixelBufferGetBytesPerRow(pb)
        let gw = w >= h ? 32 : 18, gh = w >= h ? 18 : 32
        var out = [UInt8](repeating: 0, count: gw * gh)
        for gy in 0..<gh { for gx in 0..<gw {
            let p = base + ((gy * h + h / (2 * gh)) / gh) * rb + ((gx * w + w / (2 * gw)) / gw) * 4
            out[gy * gw + gx] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
        } }
        return out
    }

    /// The alpha of `picture` (upright, any size) at the model's size, 8-bit rows top first; nil without the models.
    /// `continuous`: the frame follows the one before (playback, a scrub step), so the state carries over. `scrub`: a
    /// frame stepped to while paused, the finer model.
    func alpha(of picture: CIImage, still: Bool, scrub: Bool = false, continuous: Bool) -> (Data, Int, Int)? {
        let landscape = picture.extent.width >= picture.extent.height
        let base = still || scrub ? Self.still : Self.live
        guard let m = load(landscape ? base : (base.1, base.0)) else { return nil }
        let key = "\(m.width)x\(m.height)"
        // the picture stretched to the model's frame (16:9 or 9:16; other shapes are off by a little)
        let fitted = picture.transformed(by: .init(translationX: -picture.extent.minX, y: -picture.extent.minY))
            .transformed(by: .init(scaleX: Double(m.width) / picture.extent.width, y: Double(m.height) / picture.extent.height))
        context.render(fitted, to: m.input)

        // A cut starts the state over too: the new scene's people are not where the old one's were.
        var cut = false
        if !still {
            let sig = Self.signature(of: m.input)
            if continuous, sig.count == signature.count, !sig.isEmpty {
                var d = 0
                for i in 0..<sig.count { d += abs(Int(sig[i]) - Int(signature[i])) }
                let mean = Double(d) / Double(sig.count)
                cut = mean > Self.cutThreshold
                if Self.cutLog, cut { NSLog("subject matting: cut (luma change %.1f), the state starts over", mean) }
            }
            signature = sig
        }
        // a still frame's passes run on a state of their own: the playback's or the scrubbing's carries on after it
        var passes = 1
        var own = state
        if still {
            own = freshState(m)
            passes = Self.stillPasses
        } else if !continuous || cut || stateModel != key {
            own = freshState(m)
            stateModel = key
            if scrub { passes = Self.scrubJumpPasses }
        }
        var pha: MLMultiArray?
        for _ in 0..<passes {
            var inputs = own
            inputs["src"] = MLFeatureValue(pixelBuffer: m.input)
            guard let r = try? m.model.prediction(from: MLDictionaryFeatureProvider(dictionary: inputs)) else { return nil }
            for i in 1...4 { if let v = r.featureValue(for: "r\(i)o") { own["r\(i)i"] = v } }
            pha = r.featureValue(for: "pha")?.multiArrayValue
        }
        if !still { state = own }
        guard let a = pha, a.shape.count == 4 else { return nil }
        let h = a.shape[2].intValue, w = a.shape[3].intValue, ys = a.strides[2].intValue, xs = a.strides[3].intValue
        var out = Data(count: w * h)
        out.withUnsafeMutableBytes { (o: UnsafeMutableRawBufferPointer) in
            let ob = o.bindMemory(to: UInt8.self)
            a.withUnsafeBufferPointer(ofType: Float16.self) { p in
                for y in 0..<h { for x in 0..<w { ob[y * w + x] = UInt8(max(0, min(1, Float(p[y * ys + x * xs]))) * 255 + 0.5) } }
            }
        }
        return (out, w, h)
    }
}
