/// Puts frames that a decoder outputs in decode order back into presentation order: the smallest pts leaves once
/// more than `depth` frames wait. A frame arriving after a later one already left means `depth` was too small:
/// it is dropped and `depth` grows by one.
struct ReorderQueue<Element> {
    private(set) var depth: Int
    private var items: [(pts: Int64, element: Element)] = []
    private var lastPopped: Int64?

    init(depth: Int) {
        self.depth = max(depth, 0)
    }

    var count: Int { items.count }

    mutating func insert(_ element: Element, pts: Int64) {
        if let lastPopped, pts < lastPopped {
            depth += 1
            return
        }
        let at = items.firstIndex { $0.pts > pts } ?? items.count
        items.insert((pts, element), at: at)
    }

    /// The smallest frame, once more than `depth` wait.
    mutating func pop() -> Element? {
        items.count > depth ? popFirst() : nil
    }

    /// The smallest frame whatever the depth (end of stream).
    mutating func popAll() -> Element? {
        items.isEmpty ? nil : popFirst()
    }

    /// Before a seek: forgets the frames and what was emitted.
    mutating func removeAll() {
        items.removeAll()
        lastPopped = nil
    }

    private mutating func popFirst() -> Element {
        let first = items.removeFirst()
        lastPopped = first.pts
        return first.element
    }
}
