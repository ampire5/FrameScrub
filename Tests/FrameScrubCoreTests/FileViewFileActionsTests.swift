import Foundation
import Testing
@testable import FrameScrubCore

struct FileViewFileActionsTests {
    @Test func aConflictDoesNotStopTheRemainingFilesOrReplaceTheDestination() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let conflicting = root.appendingPathComponent("a.mov")
        let other = root.appendingPathComponent("b.mov")
        let existing = destination.appendingPathComponent("a.mov")
        try Data([1]).write(to: conflicting)
        try Data([2]).write(to: other)
        try Data([3]).write(to: existing)

        let report = FileViewFileActions.run(.move(into: destination), urls: [conflicting, other])
        #expect(report.completed == 1 && report.failures == 1)
        #expect(try Data(contentsOf: existing) == Data([3]))
        #expect(try Data(contentsOf: conflicting) == Data([1]))
        #expect(try Data(contentsOf: destination.appendingPathComponent("b.mov")) == Data([2]))
        #expect(!fm.fileExists(atPath: other.path))
    }

    @Test func copyingIntoTheSameFolderMakesCopiesAndMovingIsANoOp() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("clip.mov")
        try Data([1]).write(to: file)

        let copied = FileViewFileActions.run(.copy(into: folder), urls: [file])
        #expect(copied.completed == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent("clip copy.mov")) == Data([1]))
        let moved = FileViewFileActions.run(.move(into: folder), urls: [file])
        #expect(moved.unchanged == 1 && moved.failures == 0)
        #expect(fm.fileExists(atPath: file.path))
    }

    @Test func refusesRecursiveCopiesAndMovesThatWouldInterruptAnExport() throws {
        let fm = FileManager.default
        let folder = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source", isDirectory: true)
        let child = source.appendingPathComponent("child", isDirectory: true)
        let destination = folder.appendingPathComponent("destination", isDirectory: true)
        try fm.createDirectory(at: child, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let busyVideo = source.appendingPathComponent("clip.mov")
        try Data([1]).write(to: busyVideo)

        let recursive = FileViewFileActions.run(.copy(into: child), urls: [source])
        #expect(recursive.failures == 1)
        #expect(try fm.contentsOfDirectory(atPath: child.path).isEmpty)
        let moving = FileViewFileActions.run(.move(into: destination), urls: [source], protected: [busyVideo])
        #expect(moving.failures == 1)
        #expect(fm.fileExists(atPath: busyVideo.path))
    }

    @Test func volumeWithoutTrashReturnsFilesForConfirmation() {
        let url = URL(fileURLWithPath: "/volume/clip.mov")
        let report = FileViewFileActions.run(.trash, urls: [url], trash: { _ in
            throw CocoaError(.featureUnsupported)
        })
        #expect(report.needsConfirmation == [url])
        #expect(report.completed == 0 && report.failures == 0)
    }
}
