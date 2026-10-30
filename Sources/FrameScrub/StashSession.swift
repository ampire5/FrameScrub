import Foundation
import FrameScrubCore
import StashKitUI
import OSLog

/// Where the file on screen came from (Stash spec §3.6): a scene of Stash's, or anything else.
enum FileOrigin: Equatable {
    case plain
    case stash(sceneID: String, hasQueue: Bool)
}

/// A Stash scene's file on this Mac, Stash's stream of it, or why it cannot be opened.
enum StashFile {
    case file(URL)
    case stream(URL)
    case failed(OpenFailure)
}

/// The app side of a scene opened from Stash: finds its file on the mounted shares (mounting the share when it is
/// missing), falls back on Stash's stream by `stash-stream` (`StashOpenPolicy`), and reports what was watched back to
/// Stash (Stash spec §2.6).
@MainActor final class StashSession {
    /// "Connecting \\server\S$…" while a share is being mounted.
    var onStatus: ((String) -> Void)?
    /// The player's state, sampled once a second while a scene is open: position (s), playing forward, speed.
    var sample: (() -> (position: Double, forward: Bool, speed: Double)?)?
    /// What Stash knows about the scene on screen: `.reading` at once, then the details or the error. Called again
    /// each time a request that reached Stash changes them (plays, watched time, resume point).
    var onDetails: ((_ sceneID: String, _ state: StashDetailsState) -> Void)?
    /// The latest state reported through `onDetails`; nil when no Stash scene is on screen.
    private(set) var details: (sceneID: String, state: StashDetailsState)?
    private var detailsRequests = StashDetailsRequests()
    private let rules: [StashPathRule]
    private let streaming: StashStreaming
    private let stashURL: String
    private let client: StashClient?
    /// Stash's UI settings; nil until Stash has answered (nothing is sent before: it may have tracking off).
    private var settings: StashUISettings?
    private var fetchingSettings = false
    private var scene: (id: String, activity: StashActivity)?
    private var lastTick: Double?
    private var timer: Timer?
    private static let logger = Logger(subsystem: "local.framescrub", category: "Stash")

    init(config: Config) {
        rules = StashPathRule.parse(config.stashPathMap)
        streaming = config.stashStream
        stashURL = config.stashURL
        client = URL(string: config.stashURL).map { StashClient(baseURL: $0, apiKey: config.stashAPIKey) }
        loadSettings()
        // The last server the PC's drive letters were found on, for a restart with none of its shares mounted yet.
        rememberedDriveServer = UserDefaults.standard.string(forKey: Self.driveServerKey)
    }

    private static let driveServerKey = "StashDriveServer"
    private var rememberedDriveServer: String?

    /// Asks Stash for its UI settings until it has answered once; what was watched meanwhile is held back.
    private func loadSettings() {
        guard settings == nil, !fetchingSettings, let client else { return }
        fetchingSettings = true
        Task { [weak self] in
            do {
                let loaded = try await client.uiSettings()
                guard let self else { return }
                settings = loaded
                scene?.activity.apply(minimumPlayPercent: loaded.minimumPlayPercent, enabled: loaded.trackActivity)
            } catch {
                Self.logger.error("UI settings: \(String(describing: error), privacy: .public); asked again with the next save")
            }
            self?.fetchingSettings = false
        }
    }

    /// The scene's first file on this Mac, Stash's stream of it, or why it cannot be opened. A scene without paths
    /// (a link, a plugin page that named only the id) has them asked of Stash first.
    func resolve(_ scene: StashScene, completion: @escaping @MainActor (StashFile) -> Void) {
        guard scene.paths.isEmpty, streaming != .always else {
            decide(sceneID: scene.id, paths: scene.paths, completion: completion)
            return
        }
        guard let client else {
            completion(.failed(OpenFailure(reason: "No Stash server to ask about the scene.", detail: "Stash scene \(scene.id)")))
            return
        }
        Task { [weak self] in
            let paths: [String]
            do {
                paths = try await client.scenePaths(id: scene.id)
            } catch {
                Self.logger.error("Paths of scene \(scene.id, privacy: .public): \(String(describing: error), privacy: .public)")
                completion(.failed(OpenFailure(reason: error.localizedDescription, detail: "Stash scene \(scene.id)")))
                return
            }
            self?.decide(sceneID: scene.id, paths: paths, completion: completion)
        }
    }

    /// `StashOpenPolicy` over the shares mounted now; a share it names is mounted, then the policy is asked again
    /// (`mountAllowed: false`). A share that will not mount is replaced by the stream when `stash-stream` is `auto`.
    private func decide(sceneID: String, paths: [String], mountAllowed: Bool = true,
                        completion: @escaping @MainActor (StashFile) -> Void) {
        let decision = StashOpenPolicy.decide(sceneID: sceneID, paths: paths, resolve: { map().resolve($0) },
                                              streaming: streaming, stashURL: stashURL, mountAllowed: mountAllowed)
        switch decision {
        case let .local(url):
            completion(.file(url))
        case let .stream(url):
            completion(.stream(url))
        case let .unavailable(failure):
            completion(.failed(failure))
        case let .needsMount(smbURL, path):
            let unc = Self.unc(smbURL)
            onStatus?("Connecting \(unc)…")
            ShareMounter.mount(smbURL) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    decide(sceneID: sceneID, paths: paths, mountAllowed: false, completion: completion)
                case let .failure(error):
                    if let stream = StashOpenPolicy.streamAfterMountFailure(sceneID: sceneID, streaming: streaming,
                                                                            stashURL: stashURL) {
                        completion(.stream(stream))
                    } else {
                        completion(.failed(OpenFailure(reason: "Cannot connect \(unc): \(error.localizedDescription)", detail: path)))
                    }
                }
            }
        }
    }

    /// A scene's file is on screen: its watched time counts from now.
    func began(sceneID: String, duration: Double) {
        leave()
        scene = (sceneID, StashActivity(duration: duration, minimumPlayPercent: settings?.minimumPlayPercent ?? 0,
                                        enabled: settings?.trackActivity ?? true))
        loadSettings()
        loadDetails(sceneID: sceneID)
        lastTick = nil
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Playback paused, or a step through the queue begins: what was watched so far goes to Stash, and the scene keeps
    /// being followed (a step may find no next scene and the file plays on).
    func saveProgress() {
        guard var scene, let state = sample?() else { return }
        let requests = scene.activity.flush(position: state.position)
        self.scene = scene
        send(requests, sceneID: scene.id)
    }

    /// The file on screen is left (closed, another file, a queue step, quit): the rest goes to Stash.
    func leave() {
        timer?.invalidate()
        timer = nil
        detailsRequests.cancel()
        details = nil
        guard var scene else { return }
        self.scene = nil
        if let state = sample?() { send(scene.activity.flush(position: state.position), sceneID: scene.id) }
    }

    /// Asks Stash for the scene's details; an answer for a scene that is no longer on screen is dropped.
    private func loadDetails(sceneID: String) {
        guard let client else { return }
        let token = detailsRequests.begin(sceneID: sceneID)
        report(sceneID, .reading)
        Task { [weak self] in
            let state: StashDetailsState
            do {
                state = .loaded(try await client.sceneDetails(id: sceneID))
            } catch {
                Self.logger.error("Details of scene \(sceneID, privacy: .public): \(String(describing: error), privacy: .public)")
                state = .failed(error.localizedDescription)
            }
            guard let self, detailsRequests.accepts(sceneID: sceneID, token: token) else { return }
            report(sceneID, state)
        }
    }

    /// Stash took `request`, sent while the details request `token` was current: the loaded details of the same
    /// scene follow. Not once the scene was left (or for the write sent as it was left): details loaded when it is
    /// opened again already have the write.
    private func applied(_ request: StashActivityRequest, sceneID: String, token: Int?) {
        guard let token, detailsRequests.accepts(sceneID: sceneID, token: token),
              let details, details.sceneID == sceneID, case let .loaded(loaded) = details.state else { return }
        report(sceneID, .loaded(loaded.applying(request, at: Date())))
    }

    private func report(_ sceneID: String, _ state: StashDetailsState) {
        details = (sceneID, state)
        onDetails?(sceneID, state)
    }

    /// Stash deletes the scene, its file and its generated files.
    func destroyScene(_ sceneID: String) async throws {
        guard let client else { throw StashError.badResponse }
        try await client.destroyScene(sceneID)
    }

    /// Quitting: the last save is sent and waited for, at most 1 s.
    func flushBeforeQuit() {
        guard var scene, let client, let state = sample?() else { leave(); return }
        timer?.invalidate()
        timer = nil
        self.scene = nil
        let requests = scene.activity.flush(position: state.position)
        guard !requests.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        let id = scene.id
        Task.detached {
            for request in requests { try? await client.send(request, sceneID: id) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
    }

    /// Capture synchronously before the core closes. The returned work touches no player state and
    /// waits off-main for at most one second, so no live playback can change the sampled quit position.
    func prepareTerminationFlush() -> (@Sendable () async -> Void)? {
        guard var scene, let client, let state = sample?() else { leave(); return nil }
        timer?.invalidate()
        timer = nil
        self.scene = nil
        let requests = scene.activity.flush(position: state.position)
        guard !requests.isEmpty else { return nil }
        let id = scene.id
        return {
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                for request in requests { try? await client.send(request, sceneID: id) }
                done.signal()
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    _ = done.wait(timeout: .now() + 1)
                    continuation.resume()
                }
            }
        }
    }

    private func tick() {
        guard var scene, let state = sample?() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = lastTick.map { now - $0 } ?? 0
        lastTick = now
        let requests = scene.activity.tick(position: state.position, elapsed: elapsed, playingForward: state.forward,
                                           speed: state.speed)
        self.scene = scene
        send(requests, sceneID: scene.id)
    }

    /// Network failures never reach the screen: the watched time is carried to the next save, a play asked again.
    private func send(_ requests: [StashActivityRequest], sceneID: String) {
        guard let client, !requests.isEmpty else { return }
        guard settings != nil else {   // Stash's settings first: held back, asked again
            for request in requests { scene?.activity.failed(request) }
            loadSettings()
            return
        }
        let token = detailsRequests.currentToken
        Task { [weak self] in
            for request in requests {
                do {
                    try await client.send(request, sceneID: sceneID)
                    self?.applied(request, sceneID: sceneID, token: token)
                } catch {
                    Self.logger.error("\(String(describing: request), privacy: .public) for scene \(sceneID, privacy: .public): \(String(describing: error), privacy: .public)")
                    if let self, self.scene?.id == sceneID { self.scene?.activity.failed(request) }
                }
            }
        }
    }

    private func map() -> StashPathMap {
        let map = StashPathMap(mounts: SMBMount.current(), rules: rules, rememberedDriveServer: rememberedDriveServer)
        if let server = map.driveServer, server != rememberedDriveServer {
            rememberedDriveServer = server
            UserDefaults.standard.set(server, forKey: Self.driveServerKey)
        }
        return map
    }

    /// `smb://server/S$` → `\\server\S$`.
    static func unc(_ smbURL: URL) -> String {
        let share = smbURL.path.split(separator: "/").first.map(String.init)?.removingPercentEncoding ?? ""
        return #"\\"# + (smbURL.host ?? "") + #"\"# + share
    }
}
