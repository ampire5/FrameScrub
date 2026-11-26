import Foundation

/// Signed media addresses expire. The menu always starts a fresh extraction from the original page.
@MainActor enum RecentVideoPages {
    struct Item: Codable {
        let url: URL
        let title: String
        let itemID: String?
    }

    private static let key = "recentVideoPages"

    static var items: [Item] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Item].self, from: data)) ?? []
    }

    static func note(_ url: URL, itemID: String, title: String) {
        let entry = Item(url: url, title: title, itemID: itemID)
        let updated = [entry] + items.filter { $0.url != url || ($0.itemID != nil && $0.itemID != itemID) }
        UserDefaults.standard.set(try? JSONEncoder().encode(Array(updated.prefix(10))), forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
