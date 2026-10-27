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
    var onDisplayRatioChange: (() -> Void)?
    private(set) var displayRatio = 1.0
    private var enhanced: CIImage?
    private var enhancedFrame: Int?
    private var fadeStart: CFTimeInterval = 0
    private static let fadeDuration = 0.15

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let context: CIContext
    private let metalLayer = CAMetalLayer()
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
    private var image: CIImage?
    /// Changing either redraws the frame on screen, so a paused picture follows the settings at once.
    var scaleMode = ScaleMode.auto { didSet { if scaleMode != oldValue { needsRender = true } } }
    var sharpen = 0.3 { didSet { if sharpen != oldValue { needsRender = true } } }
    /// Crop and pixel aspect of the upright picture (aspect spec); the neural-network still gets the same crop.
    var geometry = DisplayGeometry.identity {
        didSet {
            guard geometry != oldValue else { return }
            needsRender = true
            syncPictureSize()
        }
    }
    /// Applied to the upright picture before scaling, so the neural-network still gets it too.
    private(set) var colorCorrection = ColorCorrection.identity
    private var previousColor: ColorCorrection?   // faded out over `colorFadeDuration`
    private var colorFadeStart: CFTimeInterval = 0
    private static let colorFadeDuration = 0.5
    private var skipCounter = SkippedFrameCounter()
    private var scaler: DisplayScaler!
    private var enhancedScaler: DisplayScaler!   // own MetalFX cache: the two layers differ in size
    /// The zoomed picture's own scalers, so zooming in and back to Fit never throws away the fit scaler's cache.
    private var zoomScaler: DisplayScaler!
    private var enhancedZoomScaler: DisplayScaler!
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

    init() {
        device = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        super.init(frame: .zero)
        scaler = DisplayScaler(device: device, context: context)
        enhancedScaler = DisplayScaler(device: device, context: context)
        zoomScaler = DisplayScaler(device: device, context: context)
        enhancedZoomScaler = DisplayScaler(device: device, context: context)
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    /// Stops the display link (it retains its target) so the view can be released.
    func stop() {
        frameLink?.invalidate()
        frameLink = nil
        NotificationCenter.default.removeObserver(self)
    }

    /// The scaler in use, for the stats: "MetalFX", "Lanczos".
    var scalerText: String { scaler.statusText.replacingOccurrences(of: "Scaling: ", with: "") }
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
        image = nil
        currentFrame = nil
        enhanced = nil
        enhancedFrame = nil
        imageIsHDR = false
        skipCounter.reset()
        zoomPan.reset()
        needsRender = blank
    }

    func show(_ frame: DecodedFrame) {
        skipCounter.frameArrived()
        currentFrame = frame
        enhanced = nil
        enhancedFrame = nil
        rebuildImage()
        needsRender = true
    }

    /// Cross-fades to the neural-network version of the frame that is on screen (150 ms).
    func showEnhanced(_ image: CIImage, forFrame number: Int, pts: Int64) {
        guard currentFrame?.number == number, currentFrame?.pts == pts else { return }
        if enhancedFrame == number, enhanced === image { return }   // already shown: do not restart the fade
        enhanced = image
        enhancedFrame = number
        fadeStart = CACurrentMediaTime()
        needsRender = true
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
        let atFit = zoomPan.isAtFit, refine = !zoomPan.isMoving
        func place(_ full: CIImage, using scaler: DisplayScaler, zoomScaler: DisplayScaler) -> CIImage {
            if !atFit {
                return placeZoomed(full, using: zoomScaler, refine: refine, colored: colored, commandBuffer: commandBuffer)
            }
            let source = geometry.cropped(full)
            let fitted = scaler.scaled(colored(source), to: fittedSize, mode: scaleMode, sharpen: sharpen, hdr: imageIsHDR,
                                       commandBuffer: commandBuffer)
            return fitted.transformed(by: CGAffineTransform(
                translationX: ((size.width - fitted.extent.width) / 2).rounded(),
                y: ((size.height - fitted.extent.height) / 2).rounded()))
        }
        var placed: CIImage
        if let enhanced {
            let t = min(1, (CACurrentMediaTime() - fadeStart) / Self.fadeDuration)
            let target = place(enhanced, using: enhancedScaler, zoomScaler: enhancedZoomScaler)
            if t >= 1 {
                placed = target
            } else {
                placed = place(image, using: scaler, zoomScaler: zoomScaler)
                let dissolve = CIFilter.dissolveTransition()
                dissolve.inputImage = placed
                dissolve.targetImage = target
                dissolve.time = Float(t)
                placed = dissolve.outputImage ?? target
                needsRender = true    // keep drawing until the fade is done
            }
        } else {
            placed = place(image, using: scaler, zoomScaler: zoomScaler)
        }
        let composed = placed.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        let destination = CIRenderDestination(width: Int(size.width), height: Int(size.height),
                                              pixelFormat: metalLayer.pixelFormat, commandBuffer: commandBuffer) {
            drawable.texture
        }
        destination.colorSpace = outputColorSpace
        _ = try? context.startTask(toRender: composed, to: destination)
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
        let scaled = scaler.scaled(colored, to: out, mode: mode, sharpen: sharpen, hdr: imageIsHDR,
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
