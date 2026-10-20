import CoreImage
import Foundation

/// One open Apple super-resolution session. Opening it loads the model (~2 GB for 1080p input),
/// so it is opened once per input size and reused.
protocol MLSession: AnyObject, Sendable {
    func upscale(_ image: CIImage, context: CIContext) async throws -> CIImage
    func end()
}

/// Shares one session between everything that upscales (export threads, saved frames, the paused
/// frame on screen). Calls run one at a time; the session closes after `idleSeconds` without
/// work, so the model does not stay in memory.
actor MLSessionPool {
    private struct Size: Equatable { var width: Int; var height: Int }

    private let idleSeconds: Double
    private let make: @Sendable (_ width: Int, _ height: Int) throws -> MLSession
    private var current: (size: Size, session: MLSession)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var idleToken = 0
    private(set) var sessionsCreated = 0

    init(idleSeconds: Double = 5, make: @escaping @Sendable (_ width: Int, _ height: Int) throws -> MLSession) {
        self.idleSeconds = idleSeconds
        self.make = make
    }

    func upscale(_ image: CIImage, context: CIContext) async throws -> CIImage {
        await acquire()
        defer { release() }
        let size = Size(width: Int(image.extent.width.rounded()), height: Int(image.extent.height.rounded()))
        if let open = current, open.size != size { close() }
        if current == nil {
            current = (size, try make(size.width, size.height))
            sessionsCreated += 1
        }
        do {
            return try await current!.session.upscale(image, context: context)
        } catch {
            close()   // do not reuse a session that failed
            throw error
        }
    }

    private func acquire() async {
        idleToken += 1   // cancels a pending idle close
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }   // release() hands the turn over, still busy
    }

    private func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
            return
        }
        busy = false
        idleToken += 1
        let token = idleToken
        let delay = idleSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            await self?.closeIfIdle(token)
        }
    }

    private func closeIfIdle(_ token: Int) {
        if !busy, token == idleToken { close() }
    }

    private func close() {
        current?.session.end()
        current = nil
    }
}
