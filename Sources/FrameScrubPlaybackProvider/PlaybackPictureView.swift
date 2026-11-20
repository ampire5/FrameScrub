import AppKit
import FrameScrubCore
import SwiftUI

struct PlaybackPictureView: NSViewRepresentable {
    let image: CGImage?
    let mediaID: Int
    let submission: Int
    let service: EnginePlayerService
    let submitted: () -> Void

    func makeNSView(context: Context) -> PictureView {
        let view = PictureView()
        view.togglePlayback = { [weak service] in service?.togglePicturePlayback() }
        service.pictureView = view
        return view
    }
    func updateNSView(_ view: PictureView, context: Context) {
        if view.show(image, mediaID: mediaID, submission: submission) {
            DispatchQueue.main.async(execute: submitted)
        }
    }
}

final class PictureView: NSView {
    private let picture = CALayer()
    private var image: CGImage?
    private var mediaID: Int?
    private var submission: Int?
    private var scale = 1.0
    private var pan = CGPoint.zero
    private var previousDrag: CGPoint?
    private var rightClickOrigin: CGPoint?
    private static let clickModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    var togglePlayback: (() -> Void)?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(picture)
        picture.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { nil }

    func show(_ image: CGImage?, mediaID: Int, submission: Int) -> Bool {
        if self.submission == submission { return false }
        self.submission = submission
        let changedMedia = self.mediaID != mediaID
        if changedMedia {
            previousDrag = nil
            cancelRightClick()
            self.mediaID = mediaID
            scale = 1
            pan = .zero
        }
        let sizeChanged = self.image?.width != image?.width || self.image?.height != image?.height
        self.image = image
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.contents = image
        if changedMedia || sizeChanged { placePicture() }
        CATransaction.commit()
        return image != nil
    }

    override func layout() {
        super.layout()
        placePicture()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window {
            previousDrag = nil
            cancelRightClick()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func magnify(with event: NSEvent) {
        scale = min(8, max(1, scale * exp(event.magnification)))
        placePicture()
    }

    override func mouseDown(with event: NSEvent) {
        cancelRightClick()
        previousDrag = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard scale > 1, let previousDrag else { return }
        pan.x += point.x - previousDrag.x
        pan.y += point.y - previousDrag.y
        self.previousDrag = point
        placePicture()
    }

    override func mouseUp(with event: NSEvent) {
        previousDrag = nil
    }

    override func rightMouseDown(with event: NSEvent) {
        cancelRightClick()
        guard image != nil, NSEvent.pressedMouseButtons & ~2 == 0,
              event.modifierFlags.isDisjoint(with: Self.clickModifiers) else { return }
        rightClickOrigin = convert(event.locationInWindow, from: nil)
    }

    override func rightMouseDragged(with event: NSEvent) {
        guard let origin = rightClickOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        if max(abs(point.x - origin.x), abs(point.y - origin.y)) >= RMBZoom.clickSlopPoints {
            cancelRightClick()
        }
    }

    override func rightMouseUp(with event: NSEvent) {
        rightMouseDragged(with: event)
        defer { cancelRightClick() }
        guard rightClickOrigin != nil, event.modifierFlags.isDisjoint(with: Self.clickModifiers),
              bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        togglePlayback?()
    }

    override func otherMouseDown(with event: NSEvent) {
        cancelRightClick()
        super.otherMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.momentumPhase.isEmpty, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            cancelRightClick()
        }
        super.scrollWheel(with: event)
    }

    func cancelRightClick() { rightClickOrigin = nil }

    override func smartMagnify(with event: NSEvent) {
        previousDrag = nil
        scale = 1
        pan = .zero
        placePicture()
    }

    private func placePicture() {
        guard let image, bounds.width > 0, bounds.height > 0 else { return }
        let w = Double(image.width), h = Double(image.height)
        let fitted = min(bounds.width / w, bounds.height / h) * scale
        let width = w * fitted, height = h * fitted
        let xroom = max(0, (width - bounds.width) / 2)
        let yroom = max(0, (height - bounds.height) / 2)
        pan.x = max(-xroom, min(xroom, pan.x))
        pan.y = max(-yroom, min(yroom, pan.y))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = CGRect(x: bounds.midX - width / 2 + pan.x,
                               y: bounds.midY - height / 2 + pan.y, width: width, height: height)
        CATransaction.commit()
    }
}
