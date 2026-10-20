import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct FileRemovalTests {
    private struct NoTrash: Error {}
    private let url = URL(fileURLWithPath: "/Volumes/nas/a.mp4")

    @Test func trashesWithoutAsking() {
        var asked = false, released = false
        let outcome = FileRemoval.remove(url, trash: { _ in }, confirmDelete: { asked = true; return true },
                                         release: { released = true }, delete: { _ in Issue.record("deleted") })
        #expect(outcome == .trashed)
        #expect(!asked && !released)
    }

    @Test func withoutATrashAsksThenReleasesAndDeletes() {
        var steps: [String] = []
        let outcome = FileRemoval.remove(url, trash: { _ in throw NoTrash() },
                                         confirmDelete: { steps.append("ask"); return true },
                                         release: { steps.append("release") }, delete: { _ in steps.append("delete") })
        #expect(outcome == .deleted)
        #expect(steps == ["ask", "release", "delete"])
    }

    @Test func cancellingLeavesTheFileAndKeepsItOpen() {
        var released = false
        let outcome = FileRemoval.remove(url, trash: { _ in throw NoTrash() }, confirmDelete: { false },
                                         release: { released = true }, delete: { _ in Issue.record("deleted") })
        #expect(outcome == .cancelled)
        #expect(!released)
    }

    @Test func aFailedDeleteIsReported() {
        let outcome = FileRemoval.remove(url, trash: { _ in throw NoTrash() }, confirmDelete: { true }, release: {},
                                         delete: { _ in throw CocoaError(.fileWriteNoPermission) })
        guard case .failed = outcome else { Issue.record("\(outcome)"); return }
    }
}
