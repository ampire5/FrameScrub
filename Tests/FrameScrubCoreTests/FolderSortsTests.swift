import Foundation
import HomeScreenModel
import Testing
@testable import FrameScrubCore

@MainActor @Suite struct FolderSortsTests {
    private let dateDown = BrowserSort(key: .date, ascending: false)

    private func store(_ url: URL?) -> FolderSorts { FolderSorts(url: url, schedule: { _, _ in }) }

    @Test func setThenReadBack() {
        let sorts = store(nil)
        #expect(sorts.sort(for: URL(filePath: "/v/a")) == nil)
        sorts.set(dateDown, for: URL(filePath: "/v/a"))
        #expect(sorts.sort(for: URL(filePath: "/v/a")) == dateDown)
        #expect(sorts.sort(for: URL(filePath: "/v/a/b")) == nil)   // not inherited
    }

    @Test func pathsAreStandardized() {
        let sorts = store(nil)
        sorts.set(dateDown, for: URL(filePath: "/v/./a/"))
        #expect(sorts.sort(for: URL(filePath: "/v/a")) == dateDown)
    }

    @Test func survivesReload() {
        let url = makeTemporaryDirectory().appendingPathComponent("folder-sorts.json")
        let first = store(url)
        first.set(dateDown, for: URL(filePath: "/v/a"))
        first.set(.standard, for: URL(filePath: "/v/b"))
        first.flush()
        let second = store(url)
        #expect(second.sort(for: URL(filePath: "/v/a")) == dateDown)
        #expect(second.sort(for: URL(filePath: "/v/b")) == .standard)
    }

    @Test func brokenFileIsSetAside() throws {
        let dir = makeTemporaryDirectory()
        let url = dir.appendingPathComponent("folder-sorts.json")
        try Data("not json".utf8).write(to: url)
        let sorts = store(url)
        #expect(sorts.sort(for: URL(filePath: "/v/a")) == nil)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(siblings.contains { $0.hasPrefix("folder-sorts.json.broken-") })
    }
}
