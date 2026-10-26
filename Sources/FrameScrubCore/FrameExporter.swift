import Foundation

/// Skip an export window whose frame is blurrier than its neighbours (sharp export spec §3.2).
public struct SharpFilter: Equatable, Sendable {
    /// 0…1: share of the neighbouring windows' median score a window's best frame needs.
    public var threshold: Double
    /// Odd number of windows the median is taken over.
    public var neighbours: Int

    public init(threshold: Double, neighbours: Int) {
        self.threshold = threshold
        self.neighbours = neighbours
    }
}

public struct ExportSettings: Sendable {
    public var naming: FrameNaming
    public var format: ImageFormat
    public var quality: Int
    public var threads: Int
    public var fallbackRoot: URL
    public var saveScale: OutputSize
    public var exportScale: OutputSize
    /// Pixel size of the screen the window is on (`fit` sizes); nil while unknown.
    public var screenPixels: CGSize?
    public var upscaler: Upscaler
    /// Each export window saves its sharpest frame rather than its first.
    public var sharpest: Bool
    public var skipBlurry: SharpFilter?
    /// 0…1: share of the picture that has to change since the last saved frame (export dedupe spec §3).
    public var skipDuplicates: Double?
    /// The on-screen colour correction, with `save-color=yes`; identity otherwise.
    public var color: ColorCorrection
    /// The on-screen crop and pixel aspect: saved frames look like the screen.
    public var geometry: DisplayGeometry

    public init(config: Config, fallbackRoot: URL = FrameNaming.defaultFallbackRoot, screenPixels: CGSize? = nil,
                color: ColorCorrection = .identity, geometry: DisplayGeometry = .identity) {
        naming = FrameNaming(directoryTemplate: config.frameDirectory, fileTemplate: config.frameTemplate)
        format = config.frameFormat
        quality = config.frameFormat == .heic ? config.heicQuality : config.jpegQuality
        threads = config.exportThreads
        self.fallbackRoot = fallbackRoot
        saveScale = config.saveScale
        exportScale = config.exportScale
        upscaler = config.saveUpscaler
        sharpest = config.exportSharp
        skipBlurry = config.exportSkipBlurry
            ? SharpFilter(threshold: Double(config.exportSharpThreshold) / 100, neighbours: config.exportSharpNeighbours) : nil
        skipDuplicates = config.exportSkipDuplicates ? Double(config.exportDuplicateChange) / 100 : nil
        self.screenPixels = screenPixels
        self.color = config.saveColor ? color : .identity
        self.geometry = geometry
    }
}

public struct SavedFrame: Sendable {
    public let url: URL
    public let usedFallbackDirectory: Bool
    /// It went to a folder other than the configured one (the fallback, or a page's `frames`): say where.
    public var namesFolder: Bool { usedFallbackDirectory || inPageFolder }
    public var inPageFolder = false
    public let fallbackReason: String?
}

/// What a range export did: files written, and windows skipped as blurry or as duplicates.
public struct ExportResult: Equatable, Sendable {
    public let written: Int
    public let blurry: Int
    public let duplicates: Int

    public init(written: Int, blurry: Int = 0, duplicates: Int = 0) {
        self.written = written
        self.blurry = blurry
        self.duplicates = duplicates
    }
}

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() { lock.withLock { cancelled = true } }
    public var isCancelled: Bool { lock.withLock { cancelled } }
}

public struct CopiedFrame: Sendable {
    public let data: Data
    public let fallbackReason: String?
}

/// Saves single frames (from the cache) and exports frame ranges with its own decoder, so
/// neither blocks scrubbing. Callbacks are delivered on background threads.
public final class FrameExporter: @unchecked Sendable {
    public let videoURL: URL
    /// What saved frames are named after (`%{video-name}`, the fallback folder): `videoURL`, or a page's scene for a
    /// stream (`SceneInfo.namingURL`).
    public let nameURL: URL
    /// A page's folder for this video's frames (`frames`), instead of `frame-dir`; the fallback when it cannot be written.
    public let folder: URL?
    public let rotationClockwise: Int
    public let settings: ExportSettings
    private let readCache: ReadCache?
    private let renderer = FrameImageRenderer()
    private let saveQueue = DispatchQueue(label: "framescrub.save", qos: .userInitiated)

    public init(videoURL: URL, nameURL: URL? = nil, folder: URL? = nil, rotationClockwise: Int, settings: ExportSettings,
                readCache: ReadCache? = nil) {
        self.videoURL = videoURL
        self.nameURL = nameURL ?? videoURL
        self.folder = folder
        self.readCache = readCache
        self.rotationClockwise = rotationClockwise
        self.settings = settings
    }

    public func saveFrame(_ frame: DecodedFrame, seconds: Double,
                          completion: @escaping (Result<SavedFrame, Error>) -> Void) {
        saveQueue.async {
            completion(Result {
                let (directory, fallback) = try self.outputDirectory()
                return try self.write(frame, seconds: seconds, into: directory, fallback: fallback, scale: self.settings.saveScale)
            })
        }
    }

    /// PNG bytes of `frame` for the clipboard. Rendering and upscaling run on the save queue.
    public func copyFrame(_ frame: DecodedFrame, completion: @escaping (Result<CopiedFrame, Error>) -> Void) {
        saveQueue.async {
            completion(Result {
                let png = try self.renderer.pngData(frame, rotationClockwise: self.rotationClockwise, scale: self.settings.saveScale,
                                                    screen: self.settings.screenPixels, upscaler: self.settings.upscaler,
                                                    color: self.settings.color, geometry: self.settings.geometry)
                return CopiedFrame(data: png.data, fallbackReason: png.fallbackReason)
            })
        }
    }

    public func exportRange(_ range: ClosedRange<Int>, selection: ExportSelection = .all, index: FrameIndex,
                            progress: @escaping (Int, Int) -> Void,
                            completion: @escaping (Result<ExportResult, Error>) -> Void) -> CancellationFlag {
        let flag = CancellationFlag()
        let thread = Thread {
            completion(Result { try self.runExport(range, selection: selection, index: index, flag: flag, progress: progress) })
        }
        thread.qualityOfService = .utility
        thread.start()
        return flag
    }

    /// The configured directory, or `<fallbackRoot>/<video-name>` when it cannot be written.
    func outputDirectory() throws -> (URL, Bool) {
        let fm = FileManager.default
        let primary = folder ?? settings.naming.directory(forVideo: nameURL)
        if (try? fm.createDirectory(at: primary, withIntermediateDirectories: true)) != nil,
           fm.isWritableFile(atPath: primary.path) {
            return (primary, false)
        }
        let fallback = FrameNaming.fallbackDirectory(forVideo: nameURL, root: settings.fallbackRoot)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return (fallback, true)
    }

    private func write(_ frame: DecodedFrame, seconds: Double, into directory: URL, fallback: Bool, scale: OutputSize) throws -> SavedFrame {
        let source = settings.geometry.displaySize(of: FrameImageRenderer.uprightSize(of: frame, rotationClockwise: rotationClockwise))
        let target = scale.targetSize(source: source, screen: settings.screenPixels) ?? source
        let name = settings.naming.fileName(forVideo: nameURL, frame: frame.number, seconds: seconds, format: settings.format,
                                            suffix: scale.suffix(source: source, target: target))
        let url = directory.appendingPathComponent(name)
        let reason = try renderer.write(frame, rotationClockwise: rotationClockwise, format: settings.format,
                           quality: settings.quality, scale: scale, screen: settings.screenPixels, upscaler: settings.upscaler,
                           color: settings.color, geometry: settings.geometry, to: url)
        var saved = SavedFrame(url: url, usedFallbackDirectory: fallback, fallbackReason: reason)
        saved.inPageFolder = !fallback && folder != nil
        return saved
    }

    /// Decodes the range once. Each window offers its first frame, or with `sharpest` every frame of it competes
    /// (sharp export spec §3.3); `skipBlurry` and `skipDuplicates` then drop windows. Progress counts windows done.
    private func runExport(_ range: ClosedRange<Int>, selection: ExportSelection, index: FrameIndex, flag: CancellationFlag,
                           progress: @escaping (Int, Int) -> Void) throws -> ExportResult {
        let (directory, fallback) = try outputDirectory()
        let selected = selection.frames(in: range, index: index)
        guard let first = selected.first else { return ExportResult(written: 0) }
        let windows = settings.sharpest ? selection.windows(in: range, index: index) : []
        let last = settings.sharpest ? range.upperBound : selected[selected.count - 1]
        let wanted = Set(selected)
        let decoder = try VideoDecoder(source: MediaSource(url: videoURL, readCache: readCache), index: index)
        try decoder.seek(toFrame: first)

        let workers = OperationQueue()
        workers.maxConcurrentOperationCount = max(1, settings.threads)
        let slots = DispatchSemaphore(value: max(1, settings.threads) * 2)   // bounds frames held in memory
        let lock = NSLock()
        var written = 0
        var blurry = 0
        var duplicates = 0
        var failure: Error?

        enum Outcome { case written, blurry, duplicate }
        func done(_ outcome: Outcome) {
            let count = lock.withLock { () -> Int in
                switch outcome {
                case .written: written += 1
                case .blurry: blurry += 1
                case .duplicate: duplicates += 1
                }
                return written + blurry + duplicates
            }
            progress(count, selected.count)
        }
        /// Queues `frame` for writing; false once the export is cancelled.
        func save(_ frame: DecodedFrame) -> Bool {
            slots.wait()
            if flag.isCancelled { slots.signal(); return false }
            let seconds = index.seconds(forPTS: frame.pts)
            workers.addOperation {
                defer { slots.signal() }
                do {
                    _ = try self.write(frame, seconds: seconds, into: directory, fallback: fallback, scale: self.settings.exportScale)
                    done(.written)
                } catch {
                    lock.withLock { if failure == nil { failure = error } }
                    flag.cancel()
                }
            }
            return true
        }
        var duplicateFilter = settings.skipDuplicates.map(DuplicateFilter.init(minimumChange:))
        /// Saves the frame a window chose unless it repeats the last saved one; false once the export is cancelled.
        func offer(_ frame: DecodedFrame) -> Bool {
            if duplicateFilter != nil {
                let signature = SceneSignature.of(FrameImageRenderer.image(for: frame, rotationClockwise: 0, toneMapToSDR: true))
                guard duplicateFilter!.keeps(signature) else { done(.duplicate); return true }
            }
            return save(frame)
        }
        func apply(_ decisions: [SharpPicker<DecodedFrame>.Decision]) -> Bool {
            for decision in decisions {
                if decision.write {
                    guard offer(decision.payload) else { return false }
                } else {
                    done(.blurry)
                }
            }
            return true
        }

        // Without `skipBlurry` every window is written: threshold 0, decided as soon as the next window starts.
        var picker = settings.sharpest || settings.skipBlurry != nil
            ? SharpPicker<DecodedFrame>(threshold: settings.skipBlurry?.threshold ?? 0, neighbours: settings.skipBlurry?.neighbours ?? 1)
            : nil
        var window = -1
        var decodeError: Error?
        // Each frame drains its own autorelease pool (true: go on): what the decoder and the sharpness meter leave
        // autoreleased holds decoded frames, IOSurfaces of VTDecoderXPCService that would pile up for the whole export.
        while !flag.isCancelled, autoreleasepool(invoking: { () -> Bool in
            let next: DecodedFrame?
            do { next = try decoder.nextFrame() } catch { decodeError = error; return false }
            guard let frame = next, frame.number <= last else { return false }
            if settings.sharpest {
                guard frame.number >= range.lowerBound else { return true }
                while window < 0 || frame.number > windows[window].upperBound { window += 1 }
            } else {
                guard wanted.contains(frame.number) else { return true }
                window += 1
            }
            if picker != nil {
                let decisions = picker!.add(window: window, score: SharpnessMeter.score(frame.pixelBuffer), payload: frame)
                return apply(decisions)
            }
            return offer(frame)
        }) {}
        if decodeError == nil, !flag.isCancelled, let decisions = picker?.finish() { _ = apply(decisions) }
        workers.waitUntilAllOperationsAreFinished()
        if let failure = failure ?? decodeError { throw failure }
        return ExportResult(written: written, blurry: blurry, duplicates: duplicates)
    }
}
