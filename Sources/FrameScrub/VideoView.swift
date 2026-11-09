import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import FrameScrubCore
import Metal
import QuartzCore

/// Draws the current frame with Core Image into an EDR-capable CAMetalLayer (HDR stays HDR on
/// capable displays), drives the display link and forwards input to closures.
final class VideoView: NSView {
    var rotationClockwise = 0
    var onKeyDown: ((NSEvent) -> Void)?
    var onKeyUp: ((NSEvent) -> Void)?
    var onScroll: ((NSEvent) -> Void)?
    var onScrollGestureReset: (() -> Void)?
    var onMagnify: ((NSEvent) -> Void)?
    var onMouseButton: ((String) -> Void)?
    /// A single left click on the picture (the slots over the video hide).
    var onLeftClick: (() -> Void)?
    /// `MBTN_MID`, `MBTN_BACK`, `MBTN_FORWARD` went down: the button, the keyboard modifiers, whether the right button
    /// is held, and the event time.
    var onOtherButton: ((MouseButton, Modifiers, Bool, Double) -> Void)?
    /// The same buttons went up: the button and the event time.
    var onOtherButtonUp: ((MouseButton, Double) -> Void)?
    var onMouseMoved: (() -> Void)?
    /// The pointer came into the view or left it.
    var onEnterExit: (() -> Void)?
    var onOpenFile: ((URL) -> Void)?
    var onTick: (() -> Void)?
    /// Called once, after the next picture is sent to the screen (then cleared).
    var onNextPicture: (() -> Void)?
    var onBenchPresented: (@MainActor @Sendable (Double) -> Void)?
    var onDisplayRatioChange: (() -> Void)?
    private(set) var displayRatio = 1.0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let metalLayer = CAMetalLayer()
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private var image: CIImage?
    let lowLatency = LowLatencyDisplay()
    var effectClock: (() -> Double)?
    private var llImage: CIImage? { lowLatency.image }
    private var llStatus: String { lowLatency.status }
    /// Changing either redraws the frame on screen, so a paused picture follows the settings at once.
    var scaleMode = ScaleMode.auto { didSet { if scaleMode != oldValue { needsRender = true } } }
    var sharpen = 0.3 { didSet { if sharpen != oldValue { needsRender = true } } }
    var artifactSettings = ArtifactFilterSettings() {
        didSet {
            guard artifactSettings != oldValue else { return }
            needsRender = true
            prepareArtifactFilters()
        }
    }
    private var artifactPipelines: ArtifactFilterPipelines?
    private var artifactPreparation: Task<Void, Never>?
    private var artifactPipelineError: String?
    private func prepareArtifactFilters() {
        guard artifactSettings.active, artifactPipelines == nil, artifactPreparation == nil, artifactPipelineError == nil else { return }
        let gpu = device
        artifactPreparation = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<ArtifactFilterPipelines, Error> in
                Result { try ArtifactFilterPipelines(device: gpu) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.artifactPreparation = nil
            switch result {
            case .success(let pipelines): self.artifactPipelines = pipelines
            case .failure(let error): self.artifactPipelineError = error.localizedDescription
            }
            self.needsRender = true
        }
    }
    /// Crop and pixel aspect of the upright picture.
    var geometry = DisplayGeometry.identity {
        didSet {
            guard geometry != oldValue else { return }
            needsRender = true
            syncPictureSize()
        }
    }
    /// Applied to the upright picture before screen scaling.
    private(set) var colorCorrection = ColorCorrection.identity
    private var previousColor: ColorCorrection?   // faded out over `colorFadeDuration`
    private var colorFadeStart: CFTimeInterval = 0
    private static let colorFadeDuration = 0.5
    private var skipCounter = SkippedFrameCounter()
    private var presentationLedger = PresentationLedger()
    private var presentationTicket: PresentationLedger.Ticket?
    private var lastPresentationAt: Double?
    private var diagnosticPlaying = true
    private var lastArrivalNumber: Int?
    private var diagnosticEpoch = UUID()
    private var lastOutputProbeHash: UInt32?
    private var diagnosticGroup: String {
        let settings = SubjectFocusSettings.shared
        let model = focusMask.map { $0.matte ? "rvm\(Int($0.image.extent.width))" : "vision\(Int($0.image.extent.width))" } ?? "no-mask"
        let style = focusDrawn?.rawValue ?? "off"
        let source = currentFrame.map { "\(CVPixelBufferGetWidth($0.pixelBuffer))x\(CVPixelBufferGetHeight($0.pixelBuffer))" } ?? "none"
        let target = metalLayer.drawableSize
        return "filters-\(artifactSettings.summary).ll-\(llStatus).\(diagnosticPlaying ? "play" : "pause").\(style).clean-\(settings.cleanEdge).\(model).\(source).out-\(Int(target.width))x\(Int(target.height))"
    }
    private var llScaler: DisplayScaler!
    private var llZoomScaler: DisplayScaler!
    private var scaler: DisplayScaler!
    /// The zoomed picture's own scalers, so zooming in and back to Fit never throws away the fit scaler's cache.
    private var zoomScaler: DisplayScaler!
    /// Zoom and pan inside the picture (Loupe's gestures).
    let zoomPan = ZoomPan()
    /// Whether the zoom gestures may act now: a video is open and nothing (Home) covers it.
    var zoomAllowed: () -> Bool = { false }
    /// The left press is a pan of the zoomed picture, not a window drag.
    private var panPress = false
    private var imageIsHDR = false
    private var currentFrame: DecodedFrame?
    private var headroom = 1.0
    private var headroomCheck = 0
    private var needsRender = false
    private var frameLink: CADisplayLink?
    private var rightUsedAsModifier = false
    private let flashLayer = CALayer()

    // Subject Focus (SubjectFocus.swift)
    /// The style asked for; nil: off.
    private(set) var subjectFocus: SubjectFocusStyle?
    private var focusDrawn: SubjectFocusStyle?      // what is drawn: the style, still kept while fading out
    private var focusFrom: SubjectFocusStyle?       // a style change cross-fades from this one
    private var focusFadeStart: CFTimeInterval?     // nil: no fade running (or waiting for the first mask)
    private var focusFadeIn = true
    private let masker = SubjectMasker()
    /// The custom look, the mask's settings and the overlay (`SubjectFocusSettings`), shared by the windows.
    private var settingsObserver: NSObjectProtocol?
    private var focusMask: SubjectMask?
    private var frameShownAt: CFTimeInterval = 0
    private var stillToken = 0
    private var framePlaying = true                 // the frame on screen came while playing (not stepped, scrubbed)
    private static let focusFade = 0.25
    /// How long a new frame waits for its own mask before it is drawn with the newest one: Vision balanced takes
    /// ~10 ms a 1080p frame on the ANE (M4 Max), so at 30–60 fps the frame's own mask is normally in.
    private static let maskWait = 0.02
    /// A frame on screen this long with no next one (paused, stepped, scrubbed to) gets its accurate mask (Vision's
    /// accurate, or RVM's still passes), unless the panel's Sharper Mask When Paused is off.
    private static let stillDelay = 0.25
    private static let focusLog = ProcessInfo.processInfo.environment["FRAMESCRUB_FOCUS_LOG"] != nil
    private var focusStats = (masks: 0, visionMs: 0.0, own: 0, latencyMs: 0.0, frames: 0, waited: 0, cpuMs: 0.0, gpuMs: 0.0, gpuFrames: 0)
    private var focusChange = (sum: 0.0, n: 0, since: 0.0)

    init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: .zero)
        lowLatency.onChange = { [weak self] in self?.needsRender = true }
        llScaler = DisplayScaler(device: device, context: context)
        llZoomScaler = DisplayScaler(device: device, context: context)
        scaler = DisplayScaler(device: device, context: context)
        zoomScaler = DisplayScaler(device: device, context: context)
        zoomPan.onChange = { [weak self] in self?.needsRender = true }
        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.colorspace = outputColorSpace
        metalLayer.framebufferOnly = false
        metalLayer.isOpaque = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        layer = metalLayer
        wantsLayer = true
        flashLayer.backgroundColor = NSColor.white.cgColor
        flashLayer.opacity = 0
        metalLayer.addSublayer(flashLayer)
        registerForDraggedTypes([.fileURL])
        masker.onMask = { [weak self] mask, ms in self?.maskArrived(mask, visionMs: ms) }
        settingsObserver = NotificationCenter.default.addObserver(forName: SubjectFocusSettings.changed, object: nil,
                                                                  queue: .main) { [weak self] note in
            let masks = note.userInfo?["masks"] as? Bool ?? false
            MainActor.assumeIsolated { self?.subjectFocusSettingsChanged(masks: masks) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Stops the display link (it retains its target) so the view can be released.
    func stop() {
        artifactPreparation?.cancel(); artifactPreparation = nil
        lowLatency.clear()
        frameLink?.invalidate()
        frameLink = nil
        NotificationCenter.default.removeObserver(self)
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    /// The scaler in use, for the stats: "MetalFX", "Lanczos".
    var scalerText: String {
        let active = zoomPan.isAtFit ? (llImage == nil ? scaler : llScaler)! : (llImage == nil ? zoomScaler : llZoomScaler)!
        let scale = active.statusText.replacingOccurrences(of: "Scaling: ", with: "")
        return scale + "; " + llStatus + "; " + (artifactPipelineError.map { "Filters unavailable: " + $0 } ?? active.artifactStatus)
    }
    /// Frames that were replaced before they were drawn.
    var skippedFrames: Int { skipCounter.skipped }

    func setColorCorrection(_ color: ColorCorrection, fade: Bool) {
        previousColor = fade ? colorCorrection : nil
        colorCorrection = color
        colorFadeStart = CACurrentMediaTime()
        needsRender = true
    }

    /// The picture on screen before scaling and colour correction (SDR frames as decoded).
    var displayedImage: CIImage? { image }
    /// The displayed frame without the parts the aspect cuts off (black bars): what auto colour analyses.
    var shownPicture: CIImage? { image.map(geometry.cropped) }

    /// Drops the displayed frame (used when a new file is opened). The old picture stays on screen until the next
    /// one is drawn, unless `blank` paints the view black now (nothing will follow: an error, no file left).
    func clear(blank: Bool = false) {
        lowLatency.clear()
        image = nil
        currentFrame = nil
        imageIsHDR = false
        focusMask = nil
        masker.reset()
        skipCounter.reset()
        presentationLedger.reset(); presentationTicket = nil; lastPresentationAt = nil
        lastArrivalNumber = nil; diagnosticEpoch = UUID()
        zoomPan.reset()
        needsRender = blank
    }

    /// `playing`: false while paused, so a frame stepped or scrubbed to gets a finer mask.
    func show(_ frame: DecodedFrame, playing: Bool = true) {
        if PlaybackDiagnostics.enabled {
            let replaced = presentationLedger.replacedBeforeSubmission
            presentationTicket = presentationLedger.arrive(at: PlaybackDiagnostics.now(), playing: playing)
            let group = diagnosticGroup
            PlaybackDiagnostics.shared.record("arrivals", 1, group: group)
            if presentationLedger.replacedBeforeSubmission > replaced {
                PlaybackDiagnostics.shared.record("replaced_before_submit", 1, group: group)
            }
            if playing, framePlaying, let previous = lastArrivalNumber, frame.number > previous + 1 {
                // A media-number gap can also be a seek or speed change: do not call it a render drop.
                PlaybackDiagnostics.shared.record("source_gap_frames", Double(frame.number - previous - 1), group: group)
            }
            if playing != framePlaying { lastPresentationAt = nil }
            lastArrivalNumber = frame.number
        }
        skipCounter.frameArrived()
        currentFrame = frame
        rebuildImage()
        needsRender = true
        framePlaying = playing
        if subjectFocus != nil { requestMask(for: frame, accurate: false) }
    }

    /// Diagnostic interval boundaries must follow pause/resume even without another decoded frame.
    func diagnosticPlaybackChanged(playing: Bool) {
        guard PlaybackDiagnostics.enabled else { return }
        if playing != diagnosticPlaying {
            lastPresentationAt = nil
            presentationLedger.advancePlaybackPeriod()
        }
        diagnosticPlaying = playing
    }

    // MARK: Subject Focus

    /// Turns the effect on (fading in once the first mask is there), to another style (a cross-fade) or off (a fade
    /// out). Off costs nothing: no Vision, no extra Core Image work.
    func setSubjectFocus(_ style: SubjectFocusStyle?) {
        guard style != subjectFocus else { return }
        let wasOn = subjectFocus != nil
        subjectFocus = style
        let now = CACurrentMediaTime()
        if let style {
            focusFrom = wasOn ? focusDrawn : nil
            if !wasOn, focusDrawn != nil {
                // turned on again during the fade out: in from where the fade out got to
                focusFadeStart = now - (1 - focusAmount(at: now)) * Self.focusFade
            } else {
                focusFadeStart = focusMask == nil ? nil : now
            }
            focusDrawn = style
            focusFadeIn = true
            if !wasOn, let frame = currentFrame { requestMask(for: frame, accurate: false) }
        } else {
            focusFrom = nil
            focusFadeIn = false
            focusFadeStart = now - (1 - focusAmount(at: now)) * Self.focusFade
        }
        needsRender = true
    }

    private static func threadCPUTime() -> Double {
        var t = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
        return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
    }

    /// The panel or the menu changed a setting: a redraw, or the masks start over (the one on screen stays until the
    /// first new one is in) when the mask's settings changed.
    private func subjectFocusSettingsChanged(masks: Bool) {
        guard subjectFocus != nil || focusDrawn != nil else { return }
        needsRender = true
        guard masks, subjectFocus != nil else { return }
        masker.reset()
        if let frame = currentFrame { requestMask(for: frame, accurate: false) }
    }

    /// 0…1: how much of the effect is drawn at `now`.
    private func focusAmount(at now: CFTimeInterval) -> Double {
        guard focusDrawn != nil else { return 0 }
        guard let start = focusFadeStart else { return focusMask == nil ? 0 : 1 }   // waiting for the first mask, or faded in
        let t = min(1, max(0, (now - start) / Self.focusFade))
        let eased = t * t * (3 - 2 * t)
        return focusFadeIn ? eased : 1 - eased
    }

    private func requestMask(for frame: DecodedFrame, accurate: Bool) {
        if !accurate { frameShownAt = CACurrentMediaTime() }
        let settings = SubjectFocusSettings.shared
        masker.submit(.init(pixelBuffer: frame.pixelBuffer, image: rotationClockwise == 0 ? nil : image,
                            frame: frame.number, accurate: accurate, vision: settings.visionQuality,
                            steadiness: settings.steadiness, scrub: !framePlaying, rvm: settings.matting,
                            mainPeople: settings.mainPeople))
        guard !accurate, settings.stillAccurate else { return }
        // a frame that stays: its accurate mask (one-shot per frame, dropped when the next frame comes)
        stillToken += 1
        let token = stillToken, number = frame.number
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stillDelay) { [weak self] in
            guard let self, token == stillToken, subjectFocus != nil, let frame = currentFrame, frame.number == number else { return }
            requestMask(for: frame, accurate: true)
        }
    }

    private func maskArrived(_ mask: SubjectMask, visionMs: Double) {
        guard subjectFocus != nil || focusDrawn != nil else { return }
        // a playback mask after the accurate one of the same frame does not replace it; a still's mask only for its frame
        if mask.accurate, mask.frame != currentFrame?.number { return }
        if let shown = focusMask, shown.accurate, shown.frame == mask.frame, !mask.accurate { return }
        if focusMask == nil, focusFadeStart == nil, focusFadeIn { focusFadeStart = CACurrentMediaTime() }
        focusMask = mask
        if PlaybackDiagnostics.enabled {
            PlaybackDiagnostics.shared.record("mask_work_ms", visionMs, group: diagnosticGroup)
            if let ms = mask.queueMilliseconds { PlaybackDiagnostics.shared.record("mask_queue_ms", ms, group: diagnosticGroup) }
        }
        needsRender = true
        // The frame on screen waited for this mask (`maskWait`): drawn now rather than at the next display-link tick, or
        // with 4K (Vision ~17 ms) plus up to a refresh of waiting the next frame often came first and this one was lost.
        if mask.frame == currentFrame?.number { render() }
        guard Self.focusLog else { return }
        focusStats.masks += 1
        focusStats.visionMs += visionMs
        if let c = mask.change { focusChange.sum += c; focusChange.n += 1 }
        if mask.frame == currentFrame?.number, !mask.accurate {
            focusStats.own += 1
            focusStats.latencyMs += (CACurrentMediaTime() - frameShownAt) * 1000
        }
        if mask.accurate { NSLog("subject focus: accurate mask for frame \(mask.frame), %.1f ms", visionMs) }
    }

    private func logFocusStats() {
        let s = focusStats
        guard Self.focusLog, s.frames >= 120 else { return }
        let now = CACurrentMediaTime(), span = focusChange.since > 0 ? now - focusChange.since : 0
        NSLog("subject focus bench: %.1f fps drawn, mask change %.3f/255 per frame", span > 0 ? Double(s.frames) / span : 0,
              focusChange.sum / Double(max(1, focusChange.n)))
        focusChange = (0, 0, now)
        NSLog("subject focus: %d frames drawn (%d with an older mask), masks %d (Vision %.1f ms avg; %d for the shown frame, %.1f ms after it came), draw CPU %.2f ms, GPU %.2f ms per frame; %d frames replaced before drawing so far",
              s.frames, s.waited, s.masks, s.visionMs / Double(max(1, s.masks)), s.own, s.latencyMs / Double(max(1, s.own)),
              s.cpuMs / Double(s.frames), s.gpuMs / Double(max(1, s.gpuFrames)), skippedFrames)
        focusStats = (0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private func rebuildImage() {
        guard let frame = currentFrame else { return }
        let plan = ToneMapPlan.resolve(range: frame.dynamicRange, displayHeadroom: headroom)
        image = FrameImageRenderer.displayImage(for: frame, rotationClockwise: rotationClockwise, plan: plan)
        imageIsHDR = plan != .none && plan != .toSDR
        syncPictureSize()
    }

    /// The zoom's picture: the shown part of the frame in square pixels.
    private func syncPictureSize() {
        guard let image else { return }
        zoomPan.setPictureSize(geometry.displaySize(of: image.extent.size))
    }

    private func refreshHeadroom() {
        let value = Double(window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        guard value != headroom else { return }
        headroom = value
        lowLatency.displayHeadroom = value
        rebuildImage()
        needsRender = true
    }

    @objc private func screenChanged() { refreshHeadroom() }

    /// Backlog 4.7: a barely visible white flash (8 %, fading in 120 ms) when a frame is saved or copied.
    func flash() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flashLayer.frame = metalLayer.bounds
        CATransaction.commit()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.08
        fade.toValue = 0
        fade.duration = 0.12
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(fade, forKey: "flash")
    }

    // MARK: Display

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        frameLink?.invalidate()
        frameLink = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        frameLink = link
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self))
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSWindow.didChangeScreenNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        refreshHeadroom()
        updateDrawableSize()
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        refreshHeadroom()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        zoomPan.setViewSize(metalLayer.drawableSize)
        needsRender = true
    }

    private func renderBlack() {
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0, let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        needsRender = false
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: metalLayer.pixelFormat, commandBuffer: commandBuffer) {
            drawable.texture
        }
        _ = try? context.startTask(toRender: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)), to: destination)
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        onTick?()
        if let effectClock { lowLatency.tick(at: effectClock()) }
        zoomPan.tick(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp)
        headroomCheck += 1
        if headroomCheck % 30 == 0 { refreshHeadroom() }   // about twice a second at 60 Hz
        render()
    }

    private func render() {
        guard needsRender else { return }
        guard let image else { renderBlack(); return }
        if window?.occlusionState.contains(.visible) == false { return }
        let size = metalLayer.drawableSize
        guard size.width > 0, size.height > 0 else { return }
        let aspect = geometry.aspect(of: image.extent.size)   // of the shown picture: cropped, in square pixels
        let fittedSize = size.width / size.height > aspect
            ? CGSize(width: (size.height * aspect).rounded(), height: size.height)
            : CGSize(width: size.width, height: (size.width / aspect).rounded())
        guard fittedSize.width >= 1, fittedSize.height >= 1 else { return }   // keeps needsRender set
        let now = CACurrentMediaTime()
        let diagnosticStart = PlaybackDiagnostics.enabled ? now : 0
        var effectGraphMilliseconds = 0.0
        var waited = false
        if subjectFocus != nil, let frame = currentFrame, let mask = focusMask, mask.frame < frame.number {
            if now - frameShownAt < Self.maskWait { return }   // its own mask is on the way; keeps needsRender set
            waited = true
        }
        let cpuStart = Self.focusLog ? Self.threadCPUTime() : 0   // the main thread's own CPU time, not the wall clock
        guard
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        needsRender = false
        let fit = fittedSize.height / geometry.cropRect(in: image.extent.size).height
        if abs(fit - displayRatio) > 0.001 {
            displayRatio = fit
            DispatchQueue.main.async { [weak self] in self?.onDisplayRatioChange?() }
        }
        let colorProgress = previousColor == nil ? 1 : (CACurrentMediaTime() - colorFadeStart) / Self.colorFadeDuration
        if colorProgress >= 1 { previousColor = nil } else { needsRender = true }   // keep drawing until the fade is done
        func colored(_ source: CIImage) -> CIImage {
            guard let previousColor else { return colorCorrection.apply(to: source) }
            return ColorCorrection.transition(from: previousColor, to: colorCorrection, progress: colorProgress, image: source)
        }
        let amount = focusAmount(at: now)
        if let start = focusFadeStart {
            if now - start < Self.focusFade {
                needsRender = true   // keep drawing until the fade is done
            } else if focusFadeIn {
                focusFadeStart = nil
                focusFrom = nil
            } else {   // faded out: nothing kept
                focusDrawn = nil
                focusFadeStart = nil
                focusMask = nil
                masker.reset()
            }
        }
        func focused(_ full: CIImage) -> CIImage {
            let start = PlaybackDiagnostics.enabled ? PlaybackDiagnostics.now() : 0
            defer { if PlaybackDiagnostics.enabled { effectGraphMilliseconds += (PlaybackDiagnostics.now() - start) * 1000 } }
            guard let style = focusDrawn, let focusMask, amount > 0 else { return full }
            let mask = focusMask.image, matte = focusMask.matte
            let crossFade = focusFrom != nil && focusFadeStart != nil
            let settings = SubjectFocusSettings.shared
            let out = SubjectFocusEffect.apply(to: full, mask: mask, matte: matte, look: settings.look(style),
                                               amount: crossFade ? 1 : amount, cleanEdge: settings.cleanEdge,
                                               overlay: settings.showMask)
            guard crossFade, let from = focusFrom else { return out }
            let before = SubjectFocusEffect.apply(to: full, mask: mask, matte: matte, look: settings.look(from), amount: 1,
                                                  cleanEdge: settings.cleanEdge, overlay: settings.showMask)
            return before.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: out, kCIInputTimeKey: amount])
                .cropped(to: full.extent)
        }
        let atFit = zoomPan.isAtFit, refine = !zoomPan.isMoving
        func place(_ full: CIImage, using scaler: DisplayScaler, zoomScaler: DisplayScaler) -> CIImage {
            if !atFit {
                return placeZoomed(focused(full), using: zoomScaler, refine: refine, colored: colored, commandBuffer: commandBuffer)
            }
            let source = geometry.cropped(focused(full))
            let fitted = scaler.scaled(colored(source), to: fittedSize, mode: scaleMode, sharpen: lowLatency.didUpscale ? 0 : sharpen, hdr: imageIsHDR, artifactSettings: artifactSettings, artifactPipelines: artifactPipelines, grainSeed: UInt32(truncatingIfNeeded: currentFrame?.number ?? 0),
                                       commandBuffer: commandBuffer)
            return fitted.transformed(by: CGAffineTransform(
                translationX: ((size.width - fitted.extent.width) / 2).rounded(),
                y: ((size.height - fitted.extent.height) / 2).rounded()))
        }
        let placed = place(llImage ?? image, using: llImage == nil ? scaler : llScaler, zoomScaler: llImage == nil ? zoomScaler : llZoomScaler)
        let composed = placed.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: metalLayer.pixelFormat, commandBuffer: commandBuffer) {
            drawable.texture
        }
        destination.colorSpace = outputColorSpace
        _ = try? context.startTask(toRender: composed, to: destination)
        if Self.focusLog {
            focusStats.frames += 1
            if waited { focusStats.waited += 1 }
            focusStats.cpuMs += (Self.threadCPUTime() - cpuStart) * 1000
            commandBuffer.addCompletedHandler { [weak self] cb in
                let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
                DispatchQueue.main.async { self?.focusStats.gpuMs += ms; self?.focusStats.gpuFrames += 1 }
            }
            logFocusStats()
        }
        if PlaybackDiagnostics.enabled, let ticket = presentationTicket {
            let group = diagnosticGroup, epoch = diagnosticEpoch
            let report = PlaybackDiagnostics.shared
            report.record("render_encode_wall_ms", (PlaybackDiagnostics.now() - diagnosticStart) * 1000, group: group)
            // CIImage is lazy: this is graph construction, NOT time executing effects on the GPU.
            report.record("effect_graph_build_ms", effectGraphMilliseconds, group: group)
            if let frame = currentFrame, let mask = focusMask {
                if mask.frame <= frame.number { report.record("mask_lag_frames", Double(frame.number - mask.frame), group: group) }
                else { report.record("mask_from_future", 1, group: group) }
            } else if subjectFocus != nil { report.record("no_mask", 1, group: group) }
            if waited { report.record("mask_wait_expired", 1, group: group) }
            presentationLedger.submit(ticket)
            commandBuffer.addCompletedHandler { cb in
                if cb.status == .completed {
                    report.record("render_gpu_ms", (cb.gpuEndTime - cb.gpuStartTime) * 1000, group: group)
                } else { report.record("gpu_failure", 1, group: group) }
            }
            drawable.addPresentedHandler { [weak self] drawable in
                let presentedAt = drawable.presentedTime
                DispatchQueue.main.async { [weak self] in
                    guard let self, epoch == self.diagnosticEpoch, presentedAt > 0,
                          let latency = self.presentationLedger.present(ticket, at: presentedAt) else { return }
                    report.record("arrival_to_present_ms", latency, group: group)
                    report.record("unique_presented", 1, group: group)
                    if ticket.playing && self.diagnosticPlaying && self.presentationLedger.isCurrentPlaybackPeriod(ticket) {
                        if let previous = self.lastPresentationAt, presentedAt >= previous {
                            report.record("presentation_interval_ms", (presentedAt - previous) * 1000, group: group)
                        }
                        self.lastPresentationAt = presentedAt
                    }
                }
            }
        }
        // Diagnostics only: sample five tiny GPU output patches, keeping no image or user media data.
        // Unlike presentation callbacks this detects whether the presented texture's pixels actually change.
        if PlaybackDiagnostics.enabled, ProcessInfo.processInfo.environment["FRAMESCRUB_DIAGNOSTIC_OUTPUT_PROBE"] == "1",
           let storage = device.makeBuffer(length: 5 * 2048, options: .storageModeShared),
           let blit = commandBuffer.makeBlitCommandEncoder() {
            let texture = drawable.texture
            let locations: [(Double, Double)] = [(0.5,0.5), (0.35,0.35), (0.65,0.35), (0.35,0.65), (0.65,0.65)]
            for (index, location) in locations.enumerated() {
                let x = min(max(0, Int(Double(texture.width) * location.0)), max(0, texture.width - 8))
                let y = min(max(0, Int(Double(texture.height) * location.1)), max(0, texture.height - 8))
                blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: MTLOrigin(x: x, y: y, z: 0), sourceSize: MTLSize(width: min(8, texture.width), height: min(8, texture.height), depth: 1),
                          to: storage, destinationOffset: index * 2048, destinationBytesPerRow: 256, destinationBytesPerImage: 2048)
            }
            blit.endEncoding()
            let group = diagnosticGroup, epoch = diagnosticEpoch
            commandBuffer.addCompletedHandler { [weak self] cb in
                guard cb.status == .completed else {
                    NSLog("output probe GPU failure: %@", String(describing: cb.error))
                    return
                }
                let bytes = storage.contents().assumingMemoryBound(to: UInt8.self)
                var hash: UInt32 = 2166136261
                for patch in 0..<5 { for row in 0..<8 { for byte in 0..<64 {
                    hash = (hash ^ UInt32(bytes[patch * 2048 + row * 256 + byte])) &* 16777619
                } } }
                let result = hash
                DispatchQueue.main.async { [weak self] in
                    guard let self, epoch == self.diagnosticEpoch else { return }
                    PlaybackDiagnostics.shared.record("output_patch_hash", Double(result), group: group)
                    PlaybackDiagnostics.shared.record("output_patch_changed", result == self.lastOutputProbeHash ? 0 : 1, group: group)
                    self.lastOutputProbeHash = result
                }
            }
        }
        if let callback = onBenchPresented {
            onBenchPresented = nil
            drawable.addPresentedHandler { drawable in
                let time = drawable.presentedTime
                if time > 0 { DispatchQueue.main.async { callback(time) } }
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        StartupTrace.markOnce("first picture on screen")
        if let onNextPicture {
            self.onNextPicture = nil
            onNextPicture()
        }
        skipCounter.frameDrawn()
    }

    /// The zoomed picture: only the part in view is cut from the frame (with a margin of two pixels, so the filters
    /// see real neighbours at the cut), coloured and scaled to where it lands on screen. In motion it is drawn the cheap
    /// way (one bilinear transform, exact to the sub-pixel); at rest it is refined with the scaler, whose MetalFX cache
    /// then holds while the video plays at that zoom.
    private func placeZoomed(_ full: CIImage, using scaler: DisplayScaler, refine: Bool,
                             colored colorCorrected: (CIImage) -> CIImage, commandBuffer: MTLCommandBuffer) -> CIImage {
        let empty = CIImage.empty()
        let t = zoomPan.transform
        let source = geometry.cropped(full)
        let picture = t.imageSize, size = metalLayer.drawableSize
        guard picture.width > 0, picture.height > 0, source.extent.width > 0, source.extent.height > 0 else { return empty }
        // Picture units (square pixels, y down) to source pixels (y up).
        let kx = source.extent.width / picture.width, ky = source.extent.height / picture.height
        let visible = t.visibleRect.intersection(CGRect(origin: .zero, size: picture))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return empty }
        let wanted = CGRect(x: visible.minX * kx, y: (picture.height - visible.maxY) * ky,
                            width: visible.width * kx, height: visible.height * ky)
        let cut = wanted.insetBy(dx: -2, dy: -2).integral.intersection(source.extent)
        guard !cut.isNull, cut.width >= 1, cut.height >= 1 else { return empty }
        let s = t.drawnScale, sx = s / kx, sy = s / ky
        let topLeft = t.viewPoint(forImage: CGPoint(x: cut.minX / kx, y: picture.height - cut.maxY / ky))
        let x = topLeft.x, y = size.height - topLeft.y - cut.height * sy
        let piece = source.cropped(to: cut).transformed(by: CGAffineTransform(translationX: -cut.minX, y: -cut.minY))
        let colored = colorCorrected(piece)
        guard refine else { return colored.transformed(by: CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: x, ty: y)) }
        let out = CGSize(width: max(1, (cut.width * sx).rounded()), height: max(1, (cut.height * sy).rounded()))
        // MetalFX only up to 4×: past it the scaler may not be made, which would turn MetalFX off for the zoom.
        let mode = sx > 4 && (scaleMode == .auto || scaleMode == .metalfx) ? ScaleMode.lanczos : scaleMode
        let scaled = scaler.scaled(colored, to: out, mode: mode, sharpen: lowLatency.didUpscale ? 0 : sharpen, hdr: imageIsHDR, artifactSettings: artifactSettings, artifactPipelines: artifactPipelines, grainSeed: UInt32(truncatingIfNeeded: currentFrame?.number ?? 0),
                                   commandBuffer: commandBuffer)
        return scaled.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
    }

    // MARK: Input

    /// Edit > Undo / Redo (⌘Z / ⇧⌘Z) for the cut marks. Answered here, by the first responder: NSWindow, later in the
    /// chain, takes `undo:` for its own (empty) undo manager. A text field being typed in comes first with its own.
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var canUndo: () -> Bool = { false }
    var canRedo: () -> Bool = { false }
    @objc func undo(_ sender: Any?) { onUndo?() }
    @objc func redo(_ sender: Any?) { onRedo?() }

    override func keyDown(with event: NSEvent) { onKeyDown?(event) }
    override func keyUp(with event: NSEvent) { onKeyUp?(event) }
    override func scrollWheel(with event: NSEvent) {
        // A pointer drag owns its right press through release; a wheel cannot replace it midway.
        if NSEvent.pressedMouseButtons & 0b10 != 0, zoomPan.rmbDragging { return }
        // Only real scrolling cancels the right click: not zero-delta phase events or momentum.
        if NSEvent.pressedMouseButtons & 0b10 != 0, event.momentumPhase.isEmpty,
           event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            rightUsedAsModifier = true
            zoomPan.rightUp()   // the held right button scrubs now: it zooms no more
        }
        onScroll?(event)
    }
    override func magnify(with event: NSEvent) { onMagnify?(event) }

    /// A pinch bound to the continuous zoom (`PINCH_IN/OUT zoom`), about the fingers.
    func zoomMagnify(_ event: NSEvent) { zoomPan.magnify(event, at: drawablePoint(event)) }

    /// Two-finger double tap (the system's "Smart zoom"): Fit ↔ 100 % at the fingers.
    override func smartMagnify(with event: NSEvent) {
        guard zoomAllowed() else { return }
        zoomPan.smartZoom(at: drawablePoint(event))
    }

    /// `zoom N` (a key, or ⌘+scroll, which zooms about the pointer).
    func zoom(by log2Step: Double, atPointer: Bool) {
        zoomPan.zoom(by: log2Step, at: atPointer ? pointerDrawablePoint : nil)
    }

    func zoomToFit() { zoomPan.zoomToFit() }

    /// Event location in the zoom's space: drawable pixels, origin top-left, y down.
    private func drawablePoint(_ event: NSEvent) -> CGPoint {
        drawablePoint(viewPoint: convert(event.locationInWindow, from: nil))
    }

    private func drawablePoint(viewPoint: CGPoint) -> CGPoint {
        let p = convertToBacking(viewPoint)
        return CGPoint(x: p.x, y: metalLayer.drawableSize.height - p.y)
    }

    /// The pointer, when it is over the view.
    private var pointerDrawablePoint: CGPoint? {
        guard let window else { return nil }
        let p = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(p) ? drawablePoint(viewPoint: p) : nil
    }

    /// A right drag up or down zooms about the press point (`ZoomPan`); a click stays `MBTN_RIGHT`.
    override func rightMouseDown(with event: NSEvent) {
        onScrollGestureReset?()
        rightUsedAsModifier = false
        if zoomAllowed() { zoomPan.rightDown(at: drawablePoint(event)) }
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard !rightUsedAsModifier || zoomPan.rmbDragging else { return }
        if zoomPan.rightDragged(to: drawablePoint(event), backing: window?.backingScaleFactor ?? 2) {
            rightUsedAsModifier = true
        }
    }

    /// MBTN_RIGHT fires on release, and not when the button was used as a modifier (scroll, another button, a zoom).
    override func rightMouseUp(with event: NSEvent) {
        zoomPan.rightUp()
        if !rightUsedAsModifier { onMouseButton?("MBTN_RIGHT") }
    }
    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?()
    }

    /// A button the Logitech mouse reported went down while the right one is held: like an AppKit button then, the
    /// right release is no `MBTN_RIGHT`.
    func noteRightUsedAsModifier() {
        rightUsedAsModifier = true
        zoomPan.rightUp()
    }
    override func mouseEntered(with event: NSEvent) { onEnterExit?() }
    override func mouseExited(with event: NSEvent) { onEnterExit?() }

    override func otherMouseDown(with event: NSEvent) {
        guard let button = MouseButton(appKitButtonNumber: event.buttonNumber) else { return super.otherMouseDown(with: event) }
        let rightHeld = NSEvent.pressedMouseButtons & 0b10 != 0
        if rightHeld { rightUsedAsModifier = true }
        onOtherButton?(button, Modifiers(event.modifierFlags), rightHeld, event.timestamp)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let button = MouseButton(appKitButtonNumber: event.buttonNumber) else { return super.otherMouseUp(with: event) }
        onOtherButtonUp?(button, event.timestamp)
    }

    override func mouseDown(with event: NSEvent) {
        onScrollGestureReset?()
        // A zoomed picture larger than the view is grabbed: the drag pans it instead of moving the window.
        panPress = zoomAllowed() && zoomPan.canPan
        if panPress { zoomPan.leftDown(at: drawablePoint(event), time: event.timestamp) }
        if event.clickCount == 1 { onLeftClick?() }
        if event.clickCount == 2 { onMouseButton?("MBTN_LEFT_DBL") }
    }

    /// Dragging anywhere on the picture moves the window (like other players), except in full screen; on a zoomed
    /// picture it pans (`ZoomPan`). `performDrag` instead of `isMovableByWindowBackground`, which would swallow the
    /// double click.
    override func mouseDragged(with event: NSEvent) {
        if panPress {
            if zoomPan.isDragging { NSCursor.closedHand.set() }
            zoomPan.leftDragged(to: drawablePoint(event), time: event.timestamp)
            return
        }
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        window.performDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard panPress else { return }
        panPress = false
        if zoomPan.isDragging { NSCursor.arrow.set() }
        zoomPan.leftUp(time: event.timestamp)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = fileURL(from: sender) else { return false }
        onOpenFile?(url)
        return true
    }

    private func fileURL(from info: NSDraggingInfo) -> URL? {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                            options: [.urlReadingFileURLsOnly: true])?.first as? URL
    }
}

extension VideoView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): canUndo()
        case #selector(redo(_:)): canRedo()
        default: true
        }
    }
}
