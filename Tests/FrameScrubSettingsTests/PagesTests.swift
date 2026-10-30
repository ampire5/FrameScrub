import Foundation
import SettingsKit
import Testing
@testable import FrameScrubCore
@testable import FrameScrubSettings

/// The pages against framescrub.conf: every key the file has is on a page (or deliberately left out), once, and what
/// the rows offer is what the file takes.
@MainActor @Suite struct PagesTests {
    private var rows: [SettingsRow] {
        SettingsPanel.pages().flatMap(\.rows)
    }

    @Test func pageIDsInOrder() {
        #expect(SettingsPanel.pages().map(\.id) == ["general", "speed", "home", "scrolling", "mouse", "key-bindings",
                                                    "saving", "display", "colour", "performance", "stash", "advanced"])
    }

    @Test func everyPageKeyIsAConfKey() {
        for key in rows.compactMap(\.key) {
            #expect(Config.keys.contains(key) || key == FrameScrubSettingsStore.wheelFreeSpinKey || FrameScrubSettingsStore.thumbnailKeys.contains(key), "\(key)")
        }
    }

    @Test func everyConfKeyIsOnAPage() {
        let keys = Set(rows.compactMap(\.key))
        for key in Config.keys where !FrameScrubSettingsStore.excludedKeys.contains(key) {
            #expect(keys.contains(key), "\(key) is on no page")
        }
    }

    @Test func noKeyTwice() {
        let keys = rows.compactMap(\.key)
        #expect(keys.count == Set(keys).count, "\(Dictionary(grouping: keys, by: { $0 }).filter { $0.value.count > 1 }.keys)")
    }

    @Test func choicesAreValues() {
        for row in rows {
            guard let key = row.key, key != FrameScrubSettingsStore.wheelFreeSpinKey, !FrameScrubSettingsStore.thumbnailKeys.contains(key) else { continue }
            switch row.kind {
            case .choice(let items):
                for item in items {
                    var config = Config()
                    let taken = config.set(key, item.word)
                    #expect(taken, "\(key)=\(item.word)")
                }
            case .flags(_, let items):
                var config = Config()
                let taken = config.set(key, items.map(\.word).joined(separator: ","))
                #expect(taken, "\(key)")
            default: break
            }
        }
    }

    @Test func descriptionsNameTheDefault() {
        for row in rows where row.key != nil {
            #expect(row.description?.localizedCaseInsensitiveContains("default") == true, "\(row.key!)")
        }
    }
}
