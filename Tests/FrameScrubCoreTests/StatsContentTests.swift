import Foundation
import InfoPanelModel
import StashKit
import Testing
@testable import FrameScrubCore

@Suite struct StatsContentTests {
    private func format(audio: MediaFormat.Audio? = .init(codec: "aac", profile: "LC", sampleRate: 48_000, channels: 2, bitRate: 128_000)) -> MediaFormat {
        MediaFormat(videoCodec: "h264", videoProfile: "High", videoLevel: "4.0", pixelFormat: "yuv420p", videoBitRate: 9_900_000,
                    audio: audio, container: "QuickTime / MOV", fileBitRate: 10_000_000)
    }

    private func player(format: MediaFormat? = nil, width: Int = 1920, height: Int = 1080, sar: Double = 1, rotation: Int = 0,
                        saved: Int = 0, seek: String? = nil) -> PlayerStats {
        PlayerStats(format: format ?? self.format(), width: width, height: height, bitDepth: 10, rotation: rotation, sampleAspect: sar,
                    frameRate: 29.97, duration: 87, decoder: "h264 (VideoToolbox)", frame: 12, lastFrame: 2600, exactIndex: true,
                    time: "00:00:00.400 / 00:01:27.000", cache: "10 / 512 MiB, 40 frames", readCache: nil, seek: seek, index: "Index: scan (1.5 s)",
                    speed: "1.00", volume: "100%", saved: saved, marks: nil, abLoop: nil, sharpness: "42", change: "1.5 %",
                    lastDecodeError: nil, clips: nil)
    }

    private let picture = PictureStats(scaler: "MetalFX", skippedFrames: 0, aspect: "Aspect: Original 1.78:1", colour: "Colour: off", sceneSearch: nil)

    private func rows(_ sections: [InfoSection], _ id: String) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (sections.first { $0.id == id }?.rows ?? []).map { ($0.label, $0.value) })
    }

    @Test func plainFileSections() {
        let file = FileFacts(name: "a.mov", folder: "/tmp", size: 1000, modified: nil)
        let sections = StatsContent.sections(player: player(), file: file, picture: picture, stash: nil)
        #expect(sections.map(\.id) == ["File", "Video", "Audio", "Playback", "Picture", "Diagnostics"])
        #expect(sections.allSatisfy { !$0.rows.isEmpty })
        #expect(StatsContent.defaultOrder == ["File", "Stash", "Video", "Audio", "Playback", "Picture", "Diagnostics"])
    }

    @Test func fileRows() {
        let small = FileFacts(name: "a.mov", folder: "/tmp/dir", size: 734_003_200, modified: Date(timeIntervalSince1970: 1_700_000_000))
        let r = rows(StatsContent.sections(player: player(), file: small, picture: nil, stash: nil), "File")
        #expect(r["Name"] == "a.mov")
        #expect(r["Folder"] == "/tmp/dir")
        #expect(r["Size"] == "734.0 MB")
        #expect(r["Duration"] == "1:27")
        #expect(r["Container"] == "QuickTime / MOV, 10.0 Mbit/s overall")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        #expect(r["Modified"] == formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000)))
        let big = FileFacts(name: "b.mov", folder: "/", size: 2_500_000_000, modified: nil)
        let b = rows(StatsContent.sections(player: player(), file: big, picture: nil, stash: nil), "File")
        #expect(b["Size"] == "2.50 GB")
        #expect(b["Modified"] == nil)
    }

    @Test func fileFactsReadsTheDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("statscontent-\(UUID().uuidString).bin")
        try Data(count: 2048).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let facts = FileFacts.read(url)
        #expect(facts.name == url.lastPathComponent)
        #expect(facts.folder == url.deletingLastPathComponent().path)
        #expect(facts.size == 2048)
        #expect(facts.modified != nil)
    }

    @Test func videoRowsWithDAR() {
        let r = rows(StatsContent.sections(player: player(width: 720, height: 480, sar: 0.889), file: nil, picture: nil, stash: nil), "Video")
        #expect(r["Dimensions"] == "720 × 480, DAR 1.33")
        #expect(r["Codec"] == "h264 High L4.0, yuv420p, 9.9 Mbit/s")
        #expect(r["Bit depth"] == "10-bit")
        #expect(r["Frame rate"] == "29.970 fps")
        #expect(r["Decoder"] == "h264 (VideoToolbox)")
        let square = rows(StatsContent.sections(player: player(), file: nil, picture: nil, stash: nil), "Video")
        #expect(square["Dimensions"] == "1920 × 1080")
    }

    @Test func rotationOnlyWhenTurned() {
        #expect(rows(StatsContent.sections(player: player(rotation: 90), file: nil, picture: nil, stash: nil), "Video")["Rotation"] == "90°")
        #expect(rows(StatsContent.sections(player: player(rotation: 0), file: nil, picture: nil, stash: nil), "Video")["Rotation"] == nil)
        let portrait = rows(StatsContent.sections(player: player(rotation: 270), file: nil, picture: nil, stash: nil), "Video")
        #expect(portrait["Dimensions"] == "1080 × 1920")   // as shown
    }

    @Test func labelledLinesAreSplit() {
        let sections = StatsContent.sections(player: player(seek: "Seek: 12 ms avg"), file: nil, picture: picture, stash: nil)
        let d = rows(sections, "Diagnostics")
        #expect(d["Seek"] == "12 ms avg")
        #expect(d["Index"] == "scan (1.5 s)")
        #expect(d["Cache"] == "10 / 512 MiB, 40 frames")
        let p = rows(sections, "Picture")
        #expect(p["Aspect"] == "Original 1.78:1")
        #expect(p["Colour"] == "off")
        #expect(p["Scaler"] == "MetalFX")
        #expect(p["Scene search"] == nil)
        // A line without its label's prefix ("Seek: "): the whole line under that label.
        var odd = player(seek: "no separator")
        odd.index = "approximate"
        let o = rows(StatsContent.sections(player: odd, file: nil, picture: nil, stash: nil), "Diagnostics")
        #expect(o["Seek"] == "no separator")
        #expect(o["Index"] == "approximate")
    }

    @Test func readCacheAndSceneSearchKeepTheSpecLabels() {
        var stats = ReadStats()
        stats.bytesFromFile = 734_000_000
        stats.requests = 10
        stats.hits = 4
        stats.bytesPerSecond = 25_000_000
        stats.cacheEnabled = true
        let readLine = stats.text
        #expect(readLine == "Read: 734 MB from file, cache hits 40%, 25 MB/s")
        var p = player()
        p.readCache = readLine
        let scenes = "Scenes: 42 keyframes seen, 7 cuts, 3 GOPs checked · threshold 45"
        let pic = PictureStats(scaler: "MetalFX", skippedFrames: 0, aspect: "Aspect: Original 1.78:1", colour: "Colour: off", sceneSearch: scenes)
        let sections = StatsContent.sections(player: p, file: nil, picture: pic, stash: nil)
        #expect(rows(sections, "Diagnostics")["Read cache"] == "734 MB from file, cache hits 40%, 25 MB/s")
        #expect(rows(sections, "Picture")["Scene search"] == "42 keyframes seen, 7 cuts, 3 GOPs checked · threshold 45")
        #expect(rows(sections, "Diagnostics")["Read"] == nil && rows(sections, "Picture")["Scenes"] == nil)
    }

    @Test func playbackRows() {
        var p = player(saved: 1)
        p.marks = "2 · 00:00:05.000 total"
        p.abLoop = "00:00:03.333 – 00:00:05.333, 60 f (2.00 s), loop"
        let r = rows(StatsContent.sections(player: p, file: nil, picture: nil, stash: nil), "Playback")
        #expect(r["Frame"] == "12 / 2600 (exact index)")
        #expect(r["Time"] == "00:00:00.400 / 00:01:27.000")
        #expect(r["Speed"] == "1.00")
        #expect(r["Volume"] == "100%")
        #expect(r["Saved"] == "1")
        #expect(r["Marks"] == "2 · 00:00:05.000 total")
        #expect(r["A-B"] == "00:00:03.333 – 00:00:05.333, 60 f (2.00 s), loop")
        #expect(r["Sharpness"] == "42")
        #expect(r["Change"] == "1.5 %")
        p.exactIndex = false
        p.saved = 0
        let q = rows(StatsContent.sections(player: p, file: nil, picture: nil, stash: nil), "Playback")
        #expect(q["Frame"] == "12 / 2600 (approximate index)")
        #expect(q["Saved"] == nil)
    }

    @Test func skippedFramesOnlyWhenThereAre() {
        var pic = picture
        #expect(rows(StatsContent.sections(player: player(), file: nil, picture: pic, stash: nil), "Diagnostics")["Skipped frames"] == nil)
        pic.skippedFrames = 3
        #expect(rows(StatsContent.sections(player: player(), file: nil, picture: pic, stash: nil), "Diagnostics")["Skipped frames"] == "3")
    }

    @Test func noAudioNoSection() {
        let sections = StatsContent.sections(player: player(format: format(audio: nil)), file: nil, picture: nil, stash: nil)
        #expect(!sections.map(\.id).contains("Audio"))
    }

    @Test func audioRows() {
        let r = rows(StatsContent.sections(player: player(), file: nil, picture: nil, stash: nil), "Audio")
        #expect(r == ["Codec": "aac LC", "Channels": "stereo", "Sample rate": "48 kHz", "Bit rate": "128 kbit/s"])
    }

    @Test func noPlayerNoSections() {
        #expect(StatsContent.sections(player: nil, file: nil, picture: nil, stash: nil).isEmpty)
    }

    @Test func durationFormat() {
        #expect(StatsContent.duration(87) == "1:27")
        #expect(StatsContent.duration(3723) == "1:02:03")
        #expect(StatsContent.duration(0) == "0:00")
    }

    @Test func audioParts() {
        let audio = MediaFormat.Audio(codec: "aac", profile: "LC", sampleRate: 48_000, channels: 2, bitRate: 128_000)
        #expect(audio.codecText == "aac LC")
        #expect(audio.channelsText == "stereo")
        #expect(audio.sampleRateText == "48 kHz")
        #expect(audio.bitRateText == "128 kbit/s")
        let bare = MediaFormat.Audio(codec: "mp3", profile: nil, sampleRate: 0, channels: 0, bitRate: 0)
        #expect(bare.codecText == "mp3")
        #expect(bare.channelsText == nil && bare.sampleRateText == nil && bare.bitRateText == nil)
        #expect(MediaFormat.Audio(codec: "x", profile: nil, sampleRate: 44_100, channels: 6, bitRate: 0).channelsText == "6 ch")
        #expect(MediaFormat.Audio(codec: "x", profile: nil, sampleRate: 44_100, channels: 1, bitRate: 0).sampleRateText == "44.1 kHz")
    }

    // MARK: Stash

    private func scene(_ json: [String: Any]) -> StashSceneDetails {
        StashSceneDetails(json: json)!
    }

    private func stashRows(_ state: StashDetailsState?) -> [InfoRow] {
        StatsContent.sections(player: nil, file: nil, picture: nil, stash: state).first { $0.id == "Stash" }?.rows ?? []
    }

    @Test func stashSectionComesSecond() {
        let file = FileFacts(name: "a.mov", folder: "/tmp", size: 1000, modified: nil)
        let sections = StatsContent.sections(player: player(), file: file, picture: nil, stash: .loaded(scene(["id": "357", "title": "T"])))
        #expect(sections.map(\.id).prefix(3) == ["File", "Stash", "Video"])
        #expect(sections[1].title == "Stash")
        let none = StatsContent.sections(player: player(), file: file, picture: nil, stash: nil)
        #expect(!none.map(\.id).contains("Stash"))
    }

    @Test func stashRowsFull() {
        let played = Date(timeIntervalSince1970: 1_800_000_000)
        let json: [String: Any] = [
            "id": "357", "title": "Title", "date": "2024-05-01", "code": "C-1", "director": "Dir", "details": "Line one\nline two",
            "organized": true, "rating100": 90, "o_counter": 2, "play_count": 3,
            "last_played_at": ISO8601DateFormatter().string(from: played), "play_duration": 125.0, "resume_time": 3723.0,
            "studio": ["name": "Studio"], "performers": [["name": "Ann"], ["name": "Bo"]], "tags": [["name": "x"], ["name": "y"]],
            "urls": ["https://a.example/1", "https://b.example/2"],
            "stash_ids": [["endpoint": "https://stashdb.org/graphql", "stash_id": "abc-123"], ["endpoint": "not a url", "stash_id": "z"]],
            "scene_markers": [["seconds": 754.0, "title": "Intro", "primary_tag": ["name": "Tag"]],
                              ["seconds": 61.0, "title": "Only title"],
                              ["seconds": 5.0, "primary_tag": ["name": "Only tag"]],
                              ["seconds": 0.0]],
            "files": [["id": "1"], ["id": "2"]],
        ]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let rows = stashRows(.loaded(scene(json)))
        #expect(rows.map(\.label) == ["Title", "Date", "Studio", "Performers", "Tags", "Rating", "Plays", "Watched", "Resume", "O count",
                                      "Organized", "Code", "Director", "URLs", "StashDB", "Markers", "Files", "Scene ID", "Description"])
        let r = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        #expect(r["Title"] == "Title")
        #expect(r["Date"] == "2024-05-01")
        #expect(r["Studio"] == "Studio")
        #expect(r["Performers"] == "Ann, Bo")
        #expect(r["Tags"] == "x, y")
        #expect(r["Rating"] == "4.5 / 5")
        #expect(r["Plays"] == "3 · last \(formatter.string(from: played))")
        #expect(r["Watched"] == "2:05")
        #expect(r["Resume"] == "1:02:03")
        #expect(r["O count"] == "2")
        #expect(r["Organized"] == "yes")
        #expect(r["Code"] == "C-1")
        #expect(r["Director"] == "Dir")
        #expect(r["URLs"] == "https://a.example/1\nhttps://b.example/2")
        #expect(r["StashDB"] == "stashdb.org  abc-123\nnot a url  z")
        #expect(r["Markers"] == "4\n12:34 Intro (Tag)\n1:01 Only title\n0:05 (Only tag)\n0:00")
        #expect(r["Files"] == "2")
        #expect(r["Scene ID"] == "357")
        #expect(r["Description"] == "Line one\nline two")
    }

    @Test func stashRatingHundredIsFiveStars() {
        #expect(stashRows(.loaded(scene(["id": "1", "rating100": 100]))).first { $0.label == "Rating" }?.value == "5.0 / 5")
    }

    @Test func stashPlaysWithoutDateOrCount() {
        let none = stashRows(.loaded(scene(["id": "1", "play_count": 0])))
        #expect(!none.contains { $0.label == "Plays" })
        #expect(stashRows(.loaded(scene(["id": "1", "play_count": 2]))).first { $0.label == "Plays" }?.value == "2")
        let dateOnly = stashRows(.loaded(scene(["id": "1", "play_count": 0, "last_played_at": "2026-10-18T08:27:00Z"])))
        #expect(dateOnly.first { $0.label == "Plays" }?.value.hasPrefix("0 · last 2026-10-1") == true)
    }

    @Test func stashRowsLeaveOutMissingValues() {
        let rows = stashRows(.loaded(scene(["id": "357", "organized": false, "files": [["id": "1"]]])))
        #expect(rows.map { "\($0.label): \($0.value)" } == ["Organized: no", "Scene ID: 357"])
    }

    @Test func readingAndFailed() {
        #expect(stashRows(.reading).map { "\($0.label): \($0.value)" } == ["Stash: Reading…"])
        #expect(stashRows(.failed("Stash is down")).map { "\($0.label): \($0.value)" } == ["Error: Stash is down"])
    }
}
