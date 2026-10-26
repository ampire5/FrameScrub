import Foundation
import Testing
@testable import FrameScrubCore

/// The one owner of input.conf and the profile's file: edits land in the file asked for, the map follows at once.
@Suite struct InputPreferencesTests {
    private func directory(input: String? = nil, viewing: String? = nil) throws -> URL {
        let dir = makeTemporaryDirectory()
        if let input { try input.write(to: dir.appendingPathComponent("input.conf"), atomically: true, encoding: .utf8) }
        if let viewing {
            try viewing.write(to: dir.appendingPathComponent("input-viewing.conf"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test func urlsOfTheFiles() throws {
        let dir = try directory()
        let prefs = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic, profile: .viewing)
        #expect(prefs.url(of: .main).lastPathComponent == "input.conf")
        #expect(prefs.url(of: .profile).lastPathComponent == "input-viewing.conf")
        prefs.profile = .editing
        #expect(prefs.url(of: .profile).lastPathComponent == "input-editing.conf")
    }

    @Test func editWritesTheProfileFile() throws {
        let dir = try directory(input: "SPACE ignore\n")
        let prefs = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic, profile: .viewing)
        var heard = 0
        prefs.addObserver { _ in heard += 1 }
        try prefs.edit(.profile) { $0 + "MBTN_BACK cycle pause\n" }
        let written = try String(contentsOf: dir.appendingPathComponent("input-viewing.conf"), encoding: .utf8)
        #expect(written == "MBTN_BACK cycle pause\n")
        #expect(try String(contentsOf: dir.appendingPathComponent("input.conf"), encoding: .utf8) == "SPACE ignore\n")
        #expect(prefs.inputMap.command(for: KeyChord(key: "MBTN_BACK")) == .cyclePause)
        #expect(prefs.inputMap.layer(of: KeyChord(key: "MBTN_BACK")) == .profileFile(.viewing))
        #expect(heard == 1)
    }

    @Test func editWritesInputConf() throws {
        let dir = try directory()
        let prefs = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic, profile: .editing)
        try prefs.edit(.main) { $0 + "F13 cycle pause\n" }
        #expect(prefs.inputMap.command(for: KeyChord(key: "F13")) == .cyclePause)
        #expect(prefs.inputMap.layer(of: KeyChord(key: "F13")) == .file)
    }

    @Test func reloadFilesSeesAnOutsideEdit() throws {
        let dir = try directory(input: "F13 cycle pause\n")
        let prefs = InputPreferences(url: dir.appendingPathComponent("input.conf"), layout: .classic, profile: .viewing)
        var heard = 0
        prefs.addObserver { _ in heard += 1 }
        #expect(!prefs.reloadFiles())                                   // nothing changed
        try "F13 frame-step\n".write(to: dir.appendingPathComponent("input-viewing.conf"), atomically: true, encoding: .utf8)
        #expect(prefs.reloadFiles())
        #expect(prefs.inputMap.command(for: KeyChord(key: "F13")) == .frameStep)
        #expect(heard == 1)
    }
}
