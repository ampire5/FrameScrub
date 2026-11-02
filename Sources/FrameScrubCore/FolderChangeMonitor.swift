import Darwin
import Foundation

/// Watches only the displayed folder. The first callback reconciles changes while its descriptor was opening.
public final class FolderChangeMonitor: @unchecked Sendable {
    private struct Request: Sendable {
        let folder: URL
        let generation: UInt64
        let changed: @Sendable () -> Void
    }
    private let lock = NSLock()
    private let events = DispatchQueue(label: "framescrub.folder-events", qos: .utility)
    private let callbackQueue: DispatchQueue
    private var generation: UInt64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var pendingEvent = false
    private var opener: LatestOnlyWorker<Request>!

    public init(callbackQueue: DispatchQueue = .main) {
        self.callbackQueue = callbackQueue
        // One open in flight, one replaceable pending path; a stalled SMB lookup cannot grow a thread queue.
        opener = LatestOnlyWorker(label: "framescrub.folder-open", qos: .utility) { [weak self] in self?.install($0) }
    }
    deinit { stop() }

    public func watch(_ folder: URL, changed: @escaping @Sendable () -> Void) {
        let token = lock.withLock { () -> UInt64 in
            generation &+= 1
            source?.cancel()
            source = nil
            pendingEvent = false
            return generation
        }
        opener.submit(Request(folder: folder, generation: token, changed: changed))
    }

    public func stop() {
        lock.withLock {
            generation &+= 1
            source?.cancel()
            source = nil
            pendingEvent = false
        }
    }

    private func install(_ request: Request) {
        guard lock.withLock({ generation == request.generation }) else { return }
        let fd = Darwin.open(request.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watched = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .revoke], queue: events)
        watched.setEventHandler { [weak self] in self?.event(request) }
        watched.setCancelHandler { Darwin.close(fd) }
        lock.withLock {
            watched.resume() // even a stale source must be activated before cancelling it
            if generation == request.generation { source = watched } else { watched.cancel() }
        }
        deliver(request)
    }

    private func event(_ request: Request) {
        let schedule = lock.withLock { () -> Bool in
            guard generation == request.generation, !pendingEvent else { return false }
            pendingEvent = true
            return true
        }
        guard schedule else { return }
        // One reread per burst, from its first event (a continuous copy cannot postpone refresh forever).
        events.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
            guard let self else { return }
            let current = self.lock.withLock { () -> Bool in
                guard self.generation == request.generation else { return false }
                self.pendingEvent = false
                return true
            }
            if current { self.deliver(request) }
        }
    }

    private func deliver(_ request: Request) {
        callbackQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.generation == request.generation }) else { return }
            request.changed()
        }
    }
}
