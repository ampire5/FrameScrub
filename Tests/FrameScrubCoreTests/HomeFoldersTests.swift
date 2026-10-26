import Foundation
import FrameScrubCore
import HomeScreenModel
import Testing

@Suite struct HomeFoldersTests {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("homefolders-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("App.app"), withIntermediateDirectories: true)
        for name in ["a.mp4", "B.MKV", "notes.txt", ".hidden.mp4"] {
            try Data(count: name == "a.mp4" ? 10 : 1).write(to: root.appendingPathComponent(name))
        }
        return root
    }

    @Test func listsSubfoldersAndVideosOnly() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let entries = try HomeFolders.entries(in: root).sorted { $0.name < $1.name }
        #expect(entries.map(\.name) == ["B.MKV", "Sub", "a.mp4"])
        #expect(entries.map(\.kind) == [.file, .folder, .file])
        #expect(entries[2].size == 10 && entries[2].id == entries[2].url.path)   // a video is found by its path
        #expect(entries[2].url.resolvingSymlinksInPath() == root.appendingPathComponent("a.mp4").resolvingSymlinksInPath())
        #expect(entries.allSatisfy { $0.canRename && $0.canTrash && $0.date != nil })
    }

    @Test func linksCountAsWhatTheyPointTo() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createSymbolicLink(at: root.appendingPathComponent("Linked"), withDestinationURL: root.appendingPathComponent("Sub"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("c.mov"), withDestinationURL: root.appendingPathComponent("a.mp4"))
        let entries = try HomeFolders.entries(in: root)
        #expect(entries.first { $0.name == "Linked" }?.kind == .folder)
        #expect(entries.first { $0.name == "c.mov" }?.kind == .file)
        let inside = try HomeFolders.entries(in: root.appendingPathComponent("Linked"))
        #expect(inside.isEmpty)   // read through the link (Sub is empty), not refused
        try Data(count: 1).write(to: root.appendingPathComponent("Sub/d.mp4"))
        #expect(try HomeFolders.entries(in: root.appendingPathComponent("Linked")).map(\.url.lastPathComponent) == ["d.mp4"])
    }

    @Test func anUnreadableFolderThrows() {
        #expect(throws: (any Error).self) { try HomeFolders.entries(in: URL(filePath: "/no/such/folder")) }
    }

    @Test func placesAreHomeThenVolumes() {
        let places = HomeFolders.places(home: URL(filePath: "/Users/me"),
                                        volumes: [URL(filePath: "/"), URL(filePath: "/Volumes/NAS")])
        #expect(places.map(\.name) == ["me", "NAS"])
        #expect(places.allSatisfy { $0.kind == .place })
    }

    @Test func upFromAPlaceIsThePlaces() {
        let places = [URL(filePath: "/Users/me"), URL(filePath: "/Volumes/NAS")]
        #expect(HomeFolders.parent(of: URL(filePath: "/Volumes/NAS"), places: places) == .places)
        #expect(HomeFolders.parent(of: URL(filePath: "/Volumes/NAS/Films"), places: places) == .folder(URL(filePath: "/Volumes/NAS")))
    }

    @Test func filesGetTheirProgressAndLength() {
        let a = BrowserEntry(url: URL(filePath: "/v/a.mp4"), name: "a.mp4", kind: .file)
        let b = BrowserEntry(url: URL(filePath: "/v/b.mp4"), name: "b.mp4", kind: .file)
        let sub = BrowserEntry(url: URL(filePath: "/v/Sub"), name: "Sub", kind: .folder)
        let out = HomeFolders.withFacts([a, b, sub], resume: { $0 == a.url ? ResumeEntry(position: 30, duration: 120) : nil },
                                        durations: ["/v/b.mp4": 65])
        #expect(out[0].subtitle == "0:30 / 2:00" && out[0].progress == 0.25)
        #expect(out[1].subtitle == "1:05" && out[1].progress == nil)
        #expect(out[2].subtitle == nil)
    }

    @Test func homeSortIsThePlaylistOrder() {
        #expect(HomeFolders.playlistOrder(BrowserSort(key: .date, ascending: false)) == (.date, false))
        #expect(HomeFolders.playlistOrder(.standard) == (.name, true))
    }
}
