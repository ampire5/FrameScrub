import CoreImage
import FrameScrubCore

/// Transforms only the displayed hover picture. Filmstrip and hover continue to share the original.
struct HoverPictureRender: Sendable {
    private static let context = CIContext(options: [.cacheIntermediates: false])
    let image: CGImage
    let geometry: DisplayGeometry
    let deliver: @MainActor @Sendable (CGImage) -> Void

    func run() {
        let transformed = geometry.thumbnail(of: image, context: Self.context) ?? image
        DispatchQueue.main.async { deliver(transformed) }
    }
}
