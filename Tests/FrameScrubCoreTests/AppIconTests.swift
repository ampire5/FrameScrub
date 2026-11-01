import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct AppIconTests {
    @Test func discoversPacksAndKeepsLooseIcons() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = root.appendingPathComponent("Animals")
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        for path in ["cat.png", "Animals/dog.png", "Animals/dog.icns", "Animals/notes.txt", ".hidden.png"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        let icons = AppIcon.userIcons(in: root)
        #expect(icons.count == 2)
        #expect(icons.first?.value == "cat")
        #expect(icons.first?.pack == nil)
        let dog = try #require(icons.last)
        #expect(dog.file.lastPathComponent == "dog.icns")
        #expect(dog.value == dog.file.path)
        #expect(dog.pack?.lastPathComponent == "Animals")
        #expect(AppIcon.url(for: dog.value, userDirectory: root, bundled: { _ in nil }) == dog.file)
    }

    @Test func discoversLinkedPacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let icons = root.appendingPathComponent("icons")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        try Data().write(to: source.appendingPathComponent("ball.png"))
        try FileManager.default.createSymbolicLink(at: icons.appendingPathComponent("Shapes"), withDestinationURL: source)
        #expect(AppIcon.userIcons(in: icons).map(\.pack?.lastPathComponent) == ["Shapes"])
    }
}
