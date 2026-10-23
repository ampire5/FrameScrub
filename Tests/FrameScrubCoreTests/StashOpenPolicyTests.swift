import Foundation
import StashKit
import Testing
@testable import FrameScrubCore

@Suite struct StashOpenPolicyTests {
    private let stash = "http://192.0.2.10:9999"
    private let share = URL(string: "smb://winbox/S$")!
    private let local = URL(fileURLWithPath: "/Volumes/S$/Media/a.mp4")
    private let stream = URL(string: "http://192.0.2.10:9999/scene/42/stream")!

    /// A path map by lookup: what each Stash path resolves to.
    private func resolver(_ table: [String: StashPathResolution]) -> (String) -> StashPathResolution {
        { table[$0] ?? .unmapped }
    }

    private func decide(_ paths: [String], _ resolve: (String) -> StashPathResolution, _ streaming: StashStreaming,
                        stashURL: String? = nil, mountAllowed: Bool = true) -> StashOpenPolicy.Decision {
        StashOpenPolicy.decide(sceneID: "42", paths: paths, resolve: resolve, streaming: streaming,
                               stashURL: stashURL ?? stash, mountAllowed: mountAllowed)
    }

    @Test func aMountedShareGivesTheFile() {
        let map = resolver([#"S:\Media\a.mp4"#: .local(local)])
        for streaming in [StashStreaming.auto, .never] {
            #expect(decide([#"S:\Media\a.mp4"#], map, streaming) == .local(local))
        }
    }

    @Test func anUnmountedShareIsMountedFirstThenNotAgain() {
        let map = resolver([#"S:\Media\a.mp4"#: .needsMount(share)])
        #expect(decide([#"S:\Media\a.mp4"#], map, .auto) == .needsMount(share, path: #"S:\Media\a.mp4"#))
        #expect(decide([#"S:\Media\a.mp4"#], map, .never) == .needsMount(share, path: #"S:\Media\a.mp4"#))
        // After the mount the path is still on no share: the stream, or the failure.
        #expect(decide([#"S:\Media\a.mp4"#], map, .auto, mountAllowed: false) == .stream(stream))
        guard case let .unavailable(failure) = decide([#"S:\Media\a.mp4"#], map, .never, mountAllowed: false) else {
            Issue.record("expected a failure"); return
        }
        #expect(failure.reason == #"No share for S:\Media\a.mp4"#)
    }

    @Test func anUnmappedPathStreamsOrFails() {
        let map = resolver([:])
        #expect(decide([#"X:\a.mp4"#], map, .auto) == .stream(stream))
        guard case let .unavailable(failure) = decide([#"X:\a.mp4"#], map, .never) else { Issue.record("expected a failure"); return }
        #expect(failure.reason == #"No share for X:\a.mp4"#)
        #expect(failure.detail.contains("stash-path-map"))
        // No Stash server to stream from either.
        guard case .unavailable = decide([#"X:\a.mp4"#], map, .auto, stashURL: "") else { Issue.record("expected a failure"); return }
    }

    @Test func noPathsStreamsOrFails() {
        let map = resolver([:])
        #expect(decide([], map, .auto) == .stream(stream))
        guard case let .unavailable(failure) = decide([], map, .never) else { Issue.record("expected a failure"); return }
        #expect(failure.reason == "The scene has no file in Stash.")
        #expect(failure.detail == "Stash scene 42")
    }

    @Test func alwaysStreamsWhateverTheShares() {
        let map = resolver([#"S:\Media\a.mp4"#: .local(local)])
        #expect(decide([#"S:\Media\a.mp4"#], map, .always) == .stream(stream))
        #expect(decide([], map, .always) == .stream(stream))
        guard case let .unavailable(failure) = decide([], map, .always, stashURL: "") else { Issue.record("expected a failure"); return }
        #expect(failure.reason == "No Stash server to stream from.")
    }

    @Test func theStreamAfterAFailedMountOnlyInAuto() {
        #expect(StashOpenPolicy.streamAfterMountFailure(sceneID: "42", streaming: .auto, stashURL: stash) == stream)
        #expect(StashOpenPolicy.streamAfterMountFailure(sceneID: "42", streaming: .never, stashURL: stash) == nil)
        #expect(StashOpenPolicy.streamAfterMountFailure(sceneID: "42", streaming: .auto, stashURL: "") == nil)
    }

    @Test func streamURLAndHeaders() {
        #expect(StashOpenPolicy.streamURL(stashURL: "http://h:9999", sceneID: "7")?.absoluteString == "http://h:9999/scene/7/stream")
        #expect(StashOpenPolicy.streamURL(stashURL: "http://h:9999/", sceneID: "7")?.absoluteString == "http://h:9999/scene/7/stream")
        #expect(StashOpenPolicy.streamURL(stashURL: "", sceneID: "7") == nil)
        var config = Config()
        config.stashURL = "http://h:9999"
        config.stashAPIKey = "k"
        #expect(StashOpenPolicy.headers(for: stream.deletingLastPathComponent(), config: config) == [:])   // another host
        #expect(StashOpenPolicy.headers(for: URL(string: "http://H:9999/scene/7/stream")!, config: config) == ["ApiKey": "k"])
        #expect(StashOpenPolicy.headers(for: URL(string: "http://h:8080/scene/7/stream")!, config: config) == [:])   // another port
        #expect(StashOpenPolicy.headers(for: URL(fileURLWithPath: "/a.mp4"), config: config) == [:])
        config.stashAPIKey = ""
        #expect(StashOpenPolicy.headers(for: URL(string: "http://h:9999/scene/7/stream")!, config: config) == [:])
    }
}
