import Foundation
import Testing
@testable import FrameScrubCore

/// `frames` on what a page opens: the folder its saved frames and clips go to.
@Suite struct PluginFramesTests {
    private func posted(_ text: String) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
    }

    private func reason(_ json: [String: Any]) -> String? {
        if case let .failure(failure) = PluginMessage.parse(json) { return failure.reason }
        return nil
    }

    @Test func itemsAndOpenCarryAFolder() {
        let list = posted(#"{"cmd":"setPlaylist","items":[{"url":"http://h/s/1","frames":"/Volumes/V/PornBox/Frames/A"},{"url":"http://h/s/2"}]}"#)
        #expect(reason(list) == nil)
        #expect(PluginMessage.frameFolders(list)
                == [URL(string: "http://h/s/1")!: URL(filePath: "/Volumes/V/PornBox/Frames/A", directoryHint: .isDirectory)])
        let open = posted(#"{"cmd":"open","url":"http://h/s/3","frames":"/tmp/f"}"#)
        #expect(PluginMessage.frameFolders(open) == [URL(string: "http://h/s/3")!: URL(filePath: "/tmp/f", directoryHint: .isDirectory)])
    }

    @Test func aFolderIsAbsolute() {
        #expect(reason(posted(#"{"cmd":"open","url":"http://h/s","frames":"Frames/A"}"#)) == "open: frames must be an absolute folder")
        #expect(reason(posted(#"{"cmd":"enqueue","items":[{"url":"http://h/s","frames":3}]}"#))
                == "enqueue: items[0]: frames must be a string")
    }

    @Test func savingThereNeedsTheSameConsentAsOpeningAFile() {
        let page = PluginOrigin(url: URL(string: "http://127.0.0.1:8000/")!)!
        var policy = PluginPolicy(trusted: [page], openAllowedText: "")
        #expect(policy.decision(forSavingFrom: page) == .needsConsent)
        policy.allowOpening(from: page)
        #expect(policy.decision(forSavingFrom: page) == .allowed)
        let other = PluginOrigin(url: URL(string: "http://evil.example/")!)!
        #expect(policy.decision(forSavingFrom: other) == .untrusted)
    }
}
