import Foundation
import HomeScreenModel
import Testing
@testable import FrameScrubCore

private let nbsp = "\u{00A0}"
private let uhd = FileFacts(width: 3840, height: 2160, duration: 8045, codec: "HEVC", fps: 23.976)

@Suite struct PlaylistRowFactsTests {
    /// Length, class and codec, as Home's cards write them (`UHD` is 3840 wide).
    @Test func detailWithFacts() {
        #expect(PlaylistRowFacts(facts: uhd, resume: nil, size: nil, date: nil).detail == "2:14:05 · UHD · HEVC")
    }

    @Test func detailWithoutFacts() {
        #expect(PlaylistRowFacts(facts: nil, resume: nil, size: 1_288_490_188, date: nil).detail == "1.3\(nbsp)GB")
        #expect(PlaylistRowFacts(facts: nil, resume: nil, size: nil, date: nil).detail == "")
    }

    /// A played file's length comes from where it was left when its facts are not known.
    @Test func detailFromResumeLength() {
        let resume = ResumeEntry(position: 10, duration: 125)
        #expect(PlaylistRowFacts(facts: nil, resume: resume, size: 2_000_000, date: nil).detail == "2:05 · 2.0\(nbsp)MB")
    }

    @Test func progressPlayed() {
        let facts = FileFacts(duration: 600)
        #expect(PlaylistRowFacts(facts: facts, resume: ResumeEntry(position: 60), size: nil, date: nil).progress == 0.1)
    }

    @Test func progressFinished() {
        let facts = FileFacts(duration: 600)
        #expect(PlaylistRowFacts(facts: facts, resume: ResumeEntry(position: 595), size: nil, date: nil).progress == nil)
    }

    @Test func progressUnplayed() {
        #expect(PlaylistRowFacts(facts: FileFacts(duration: 600), resume: nil, size: nil, date: nil).progress == nil)
    }

    @Test func cardLines() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let card = PlaylistRowFacts(facts: uhd, resume: ResumeEntry(position: 3379), size: 4_200_000_000, date: date).card
        #expect(card.count == 3)
        #expect(card[0].hasPrefix("4.2\(nbsp)GB · "))
        #expect(card[1] == "3840 × 2160 · UHD · 23.976p · HEVC")
        #expect(card[2] == "Watched 42 %")
        #expect(PlaylistRowFacts(facts: nil, resume: nil, size: nil, date: nil).card.isEmpty)
    }

    /// Rows without a local file (a scene, a stream) have no URL; a folder's file has its own.
    @Test func rowWithoutURL() {
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        #expect(PlaylistRow(file: file).url == file)
        #expect(PlaylistRow(.file(file, title: nil)).url == file)
        #expect(PlaylistRow(.scene(id: "1", title: nil)).url == nil)
        #expect(PlaylistRow(.stream(URL(string: "https://h/x.m3u8")!, title: nil)).url == nil)
    }
}
