import CoreGraphics
import Foundation

/// Shared only by preview consumers of one open file/rotation. Stores actual decoded PTS, never estimated
/// sample times. A larger picture can serve a smaller request; a small source is recorded at its requested box
/// size so asking for a larger-than-native thumbnail does not decode it repeatedly.
public final class PreviewImagePool: @unchecked Sendable {
    private struct Entry {
        let image: CGImage
        let widthPixels: Int
        var bytes: Int { image.bytesPerRow * image.height }
    }
    private let url: URL
    private let rotation: Int
    private let capacity: Int
    private let budget: Int
    private let lock = NSLock()
    private var entries: [Int64: Entry] = [:]
    private var order: [Int64] = []
    private var bytes = 0

    // Formerly each provider kept 200 entries. Share that entry limit and cap pixel residency too:
    // 32 MiB bounds larger hover pictures too; see docs/bench/2026-10-31-filmstrip-readiness.md.
    public init(url: URL, rotationClockwise: Int, capacity: Int = 200, budgetBytes: Int = 32 * 1024 * 1024) {
        self.url = url
        rotation = rotationClockwise
        self.capacity = max(1, capacity)
        budget = max(0, budgetBytes)
    }

    func matches(url: URL, rotationClockwise: Int) -> Bool { self.url == url && rotation == rotationClockwise }
    var count: Int { lock.withLock { entries.count } }

    func contains(pts: Int64, widthPixels: Int) -> Bool {
        lock.withLock { entries[pts].map { $0.widthPixels >= widthPixels } ?? false }
    }

    func image(pts: Int64, widthPixels: Int) -> CGImage? {
        lock.withLock {
            guard let entry = entries[pts], entry.widthPixels >= widthPixels else { return nil }
            touch(pts)
            return entry.image
        }
    }

    func set(_ image: CGImage, pts: Int64, widthPixels: Int) {
        let entry = Entry(image: image, widthPixels: widthPixels)
        lock.withLock {
            guard entry.bytes <= budget else { return }
            if let old = entries[pts] {
                guard old.widthPixels < widthPixels else { touch(pts); return }
                bytes -= old.bytes
            }
            entries[pts] = entry
            bytes += entry.bytes
            touch(pts)
            while order.count > capacity || bytes > budget {
                let victim = order.removeFirst()
                if let removed = entries.removeValue(forKey: victim) { bytes -= removed.bytes }
            }
        }
    }

    private func touch(_ pts: Int64) {
        order.removeAll { $0 == pts }
        order.append(pts)
    }
}
