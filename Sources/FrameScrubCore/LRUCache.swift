import Foundation

/// A small thread-safe least-recently-used cache.
final class LRUCache<Key: Hashable, Value> {
    private let capacity: Int
    private let lock = NSLock()
    private var items: [Key: Value] = [:]
    private var order: [Key] = []     // least recently used first

    init(capacity: Int) { self.capacity = max(1, capacity) }

    var count: Int { lock.withLock { items.count } }

    func get(_ key: Key) -> Value? {
        lock.withLock {
            guard let value = items[key] else { return nil }
            touch(key)
            return value
        }
    }

    func set(_ key: Key, _ value: Value) {
        lock.withLock {
            items[key] = value
            touch(key)
            while order.count > capacity { items[order.removeFirst()] = nil }
        }
    }

    private func touch(_ key: Key) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}
