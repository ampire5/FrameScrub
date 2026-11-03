import Foundation
import Network

/// Opt-in receiver for Console's Max/MSP output. One local client, one read in flight. Scheduling the next read
/// after delivery bounds queued main-thread work; the OS supplies backpressure. No polling or reconnect timer.
@MainActor final class TourBoxBridge {
    var onBytes: ([UInt8]) -> Void = { _ in }
    var onDisconnect: () -> Void = {}
    var onError: (String) -> Void = { _ in }
    private var listener: NWListener?
    private var client: NWConnection?

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 50500)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.newConnectionHandler = { [weak self, weak listener] connection in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener, self.client == nil else { connection.cancel(); return }
                    self.client = connection
                    connection.stateUpdateHandler = { [weak self, weak connection] state in
                        MainActor.assumeIsolated {
                            guard let self, let connection, self.client === connection else { return }
                            switch state {
                            case .ready: self.receive(connection)
                            case .failed, .cancelled: self.disconnected(connection)
                            default: break
                            }
                        }
                    }
                    connection.start(queue: .main)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                MainActor.assumeIsolated {
                    guard let self, self.listener === listener else { return }
                    if case let .failed(error) = state {
                        self.stop()
                        self.onError("TourBox: \(error.localizedDescription)")
                    }
                }
            }
            listener.start(queue: .main)
        } catch { onError("TourBox: \(error.localizedDescription)") }
    }

    func stop() {
        let oldClient = client, oldListener = listener
        client = nil; listener = nil
        oldClient?.cancel(); oldListener?.cancel()
        onDisconnect()
    }

    private func disconnected(_ connection: NWConnection) {
        guard client === connection else { return }
        client = nil
        connection.cancel()
        onDisconnect()
    }

    private func receive(_ connection: NWConnection) {
        // 32 bytes bound each input batch; yield to the run loop before the next batch. This is a responsiveness
        // bound, not measured encoder resolution. Real-device timing/feel remains part of the trial checklist.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32) { [weak self, weak connection] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, let connection, self.client === connection else { return }
                if let data, !data.isEmpty { self.onBytes(Array(data)) }
                guard self.client === connection else { return }
                if ended || error != nil { self.disconnected(connection) }
                else {
                    DispatchQueue.main.async { [weak self, weak connection] in
                        guard let self, let connection, self.client === connection else { return }
                        self.receive(connection)
                    }
                }
            }
        }
    }
}
