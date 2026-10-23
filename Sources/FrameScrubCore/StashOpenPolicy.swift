import Foundation
import StashKit

/// `stash-stream`: when a Stash scene plays from Stash's own stream (`<stash-url>/scene/<id>/stream`) instead of its
/// file on a share.
public enum StashStreaming: String, CaseIterable, Sendable {
    /// The file on a mounted share, mounting it when needed; the stream when no share this Mac can reach has it.
    case auto
    /// Never: a file on no reachable share fails as before.
    case never
    /// Always the stream, whatever the shares.
    case always

    public var title: String {
        switch self {
        case .auto: "When the file is on no share"
        case .never: "Never"
        case .always: "Always"
        }
    }
}

/// How a Stash scene is opened: its paths (given, or fetched from Stash by id) go through `StashPathMap` — a file on a
/// mounted share is opened as a file, a share that is not mounted is mounted first — and a scene with no reachable
/// file streams from Stash. A pure decision; `StashSession` runs the mount and the fetch around it.
public enum StashOpenPolicy {
    public enum Decision: Equatable, Sendable {
        /// The scene's file on this Mac.
        case local(URL)
        /// The `smb://` share to mount; then decide again with `mountAllowed: false`.
        case needsMount(URL, path: String)
        /// Stash's stream of the scene.
        case stream(URL)
        case unavailable(OpenFailure)
    }

    /// `<stash-url>/scene/<id>/stream`; nil without a Stash server.
    public static func streamURL(stashURL: String, sceneID: String) -> URL? {
        guard let base = URL(string: stashURL), base.host != nil else { return nil }
        return base.appendingPathComponent("scene/\(sceneID)/stream")
    }

    /// The headers a read of `url` needs: Stash's `ApiKey` for a URL on the Stash server when a key is configured.
    public static func headers(for url: URL, config: Config) -> [String: String] {
        guard !config.stashAPIKey.isEmpty, let stash = URL(string: config.stashURL),
              let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(),
              StashPathMap.isStashPage(scheme: scheme, host: host, port: url.port ?? 0, stashURL: stash) else { return [:] }
        return ["ApiKey": config.stashAPIKey]
    }

    /// The decision for a scene with `paths` (Stash's order, the primary file first), `resolve` being the path map.
    /// `mountAllowed: false` after a mount: a path still on no mounted share then counts as unreachable.
    public static func decide(sceneID: String, paths: [String], resolve: (String) -> StashPathResolution,
                              streaming: StashStreaming, stashURL: String, mountAllowed: Bool = true) -> Decision {
        let stream = streamURL(stashURL: stashURL, sceneID: sceneID)
        if streaming == .always {
            guard let stream else { return .unavailable(noServer) }
            return .stream(stream)
        }
        guard let path = paths.first else {
            if streaming == .auto, let stream { return .stream(stream) }
            return .unavailable(OpenFailure(reason: "The scene has no file in Stash.", detail: "Stash scene \(sceneID)"))
        }
        switch resolve(path) {
        case let .local(url):
            return .local(url)
        case let .needsMount(share) where mountAllowed:
            return .needsMount(share, path: path)
        case .needsMount, .unmapped:
            if streaming == .auto, let stream { return .stream(stream) }
            return .unavailable(noShare(path))
        }
    }

    /// The stream to fall back on when a share could not be mounted; nil unless `auto` with a Stash server.
    public static func streamAfterMountFailure(sceneID: String, streaming: StashStreaming, stashURL: String) -> URL? {
        streaming == .auto ? streamURL(stashURL: stashURL, sceneID: sceneID) : nil
    }

    static func noShare(_ path: String) -> OpenFailure {
        OpenFailure(reason: "No share for \(path)",
                    detail: "Mount the share on this Mac, or add a rule to stash-path-map in Settings → Stash.")
    }

    static let noServer = OpenFailure(reason: "No Stash server to stream from.", detail: "Set stash-url in Settings → Stash.")
}
