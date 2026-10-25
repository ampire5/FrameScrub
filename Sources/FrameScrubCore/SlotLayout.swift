import CoreGraphics

/// Where the shown slots and the video go in the window (AppKit coordinates, origin bottom-left). Pinned slots take
/// their room from the video: the sides the whole height, the bottom between the pinned sides. Overlay slots go the
/// same way inside what is left for the video, which keeps its size. A pinned slot that would leave the video smaller
/// than `minVideo` lies over it instead, the most recently shown first.
public struct SlotLayout: Equatable, Sendable {
    public static let minVideo = CGSize(width: 480, height: 270)

    public struct Input: Sendable {
        public var container: CGRect
        /// The shown slots; the size is a width for the sides, a height for the bottom.
        public var slots: [SlotEdge: (mode: SlotMode, size: CGFloat)]
        /// The order the slots were shown in, oldest first; a slot missing here counts as the oldest.
        public var order: [SlotEdge]

        public init(container: CGRect, slots: [SlotEdge: (mode: SlotMode, size: CGFloat)], order: [SlotEdge]) {
            self.container = container
            self.slots = slots
            self.order = order
        }
    }

    public var video: CGRect
    public var slots: [SlotEdge: CGRect]
    /// Each shown slot's mode as laid out: a pinned slot may have become an overlay.
    public var effectiveMode: [SlotEdge: SlotMode]
    /// The pinned slots laid out as overlays, newest first.
    public var demoted: [SlotEdge]
    /// The height of an overlay bottom slot (the seek bar goes above it), else 0.
    public var seekBarBottomInset: CGFloat

    public static func compute(_ input: Input) -> SlotLayout {
        let shownOrder = SlotEdge.allCases.filter { input.slots[$0] != nil && !input.order.contains($0) }
            + input.order.filter { input.slots[$0] != nil }
        var pinned = shownOrder.filter { input.slots[$0]!.mode == .pinned }
        var demoted: [SlotEdge] = []
        var placed = place(Set(pinned), sizes: input.slots, in: input.container)
        while !pinned.isEmpty,
              placed.inner.width < minVideo.width || placed.inner.height < minVideo.height {
            demoted.append(pinned.removeLast())
            placed = place(Set(pinned), sizes: input.slots, in: input.container)
        }
        let video = placed.inner
        let overlays = Set(input.slots.keys).subtracting(pinned)
        let floating = place(overlays, sizes: input.slots, in: video)
        var modes: [SlotEdge: SlotMode] = [:]
        for edge in input.slots.keys { modes[edge] = pinned.contains(edge) ? .pinned : .overlay }
        return SlotLayout(video: video, slots: placed.rects.merging(floating.rects) { a, _ in a },
                          effectiveMode: modes, demoted: demoted,
                          seekBarBottomInset: floating.rects[.bottom]?.height ?? 0)
    }

    /// `edges` laid out in `rect`: the sides the whole height, the bottom between them; `inner` is what is left.
    private static func place(_ edges: Set<SlotEdge>, sizes: [SlotEdge: (mode: SlotMode, size: CGFloat)],
                              in rect: CGRect) -> (rects: [SlotEdge: CGRect], inner: CGRect) {
        func size(_ edge: SlotEdge, limit: CGFloat) -> CGFloat {
            edges.contains(edge) ? min(max(sizes[edge]!.size, 0), limit) : 0
        }
        let left = size(.left, limit: rect.width)
        let right = size(.right, limit: rect.width - left)
        let bottom = size(.bottom, limit: rect.height)
        var rects: [SlotEdge: CGRect] = [:]
        if edges.contains(.left) { rects[.left] = CGRect(x: rect.minX, y: rect.minY, width: left, height: rect.height) }
        if edges.contains(.right) {
            rects[.right] = CGRect(x: rect.maxX - right, y: rect.minY, width: right, height: rect.height)
        }
        let between = CGRect(x: rect.minX + left, y: rect.minY, width: rect.width - left - right, height: rect.height)
        if edges.contains(.bottom) {
            rects[.bottom] = CGRect(x: between.minX, y: between.minY, width: between.width, height: bottom)
        }
        return (rects, CGRect(x: between.minX, y: between.minY + bottom, width: between.width,
                              height: between.height - bottom))
    }
}
