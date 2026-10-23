import Foundation
import Network

/// A small HTTP/1.1 server on the loopback interface serving one file at `/file` with Range support, for the
/// `HTTPByteSource` tests: ranged GETs answer 206 with `Content-Range`, a GET without a range the whole file, a range
/// past the end 416, any other path 404. Every request is recorded (`requests`), and `rangesSupported: false` makes
/// it ignore ranges like a plain file server would. `requiredHeader` refuses requests without that header with 401.
final class RangeServer: @unchecked Sendable {
    struct Request: Equatable {
        var method: String
        var path: String
        var range: ClosedRange<Int64>?
        var headers: [String: String]
    }

    private(set) var url = URL(string: "http://127.0.0.1/file")!
    private let data: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "rangeserver")
    private let lock = NSLock()
    private var recorded: [Request] = []
    private var connections: [NWConnection] = []
    var rangesSupported = true
    var requiredHeader: (field: String, value: String)?

    init(file: URL) throws {
        data = try Data(contentsOf: file)
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var port: UInt16 = 0
        let listener = self.listener
        listener.stateUpdateHandler = { state in
            if case .ready = state { port = listener.port?.rawValue ?? 0; ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, port != 0 else { throw URLError(.cannotConnectToHost) }
        url = URL(string: "http://127.0.0.1:\(port)/file")!
    }

    deinit { stop() }

    func stop() {
        listener.cancel()
        lock.withLock { connections }.forEach { $0.cancel() }
    }

    var requests: [Request] { lock.withLock { recorded } }
    var size: Int64 { Int64(data.count) }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    /// Reads one request's head (a body is never expected), answers it and waits for the next on the same connection.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] chunk, _, complete, error in
            guard let self, error == nil, let chunk, !chunk.isEmpty else { connection.cancel(); return }
            var buffer = buffered
            buffer.append(chunk)
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete { receive(on: connection, buffered: buffer) }
                return
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
            let rest = buffer[end.upperBound...]
            let response = respond(to: head)
            connection.send(content: response, completion: .contentProcessed { _ in
                self.receive(on: connection, buffered: Data(rest))
            })
        }
    }

    private func respond(to head: String) -> Data {
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2 else { return response(400, body: Data(), headers: []) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let range = headers["range"].flatMap(Self.range(from:))
        lock.withLock { recorded.append(Request(method: parts[0], path: parts[1], range: range, headers: headers)) }
        let isHead = parts[0] == "HEAD"
        guard parts[1] == "/file" else { return response(404, body: Data("not here".utf8), headers: [], head: isHead) }
        if let required = requiredHeader, headers[required.field.lowercased()] != required.value {
            return response(401, body: Data(), headers: [], head: isHead)
        }
        guard let range, rangesSupported else {
            return response(200, body: data, headers: ["Accept-Ranges: bytes"], head: isHead)
        }
        guard range.lowerBound < data.count else {
            return response(416, body: Data(), headers: ["Content-Range: bytes */\(data.count)"], head: isHead)
        }
        let last = min(range.upperBound, Int64(data.count) - 1)
        let slice = data[Int(range.lowerBound)...Int(last)]
        return response(206, body: Data(slice), headers: ["Accept-Ranges: bytes", "Content-Range: bytes \(range.lowerBound)-\(last)/\(data.count)"], head: isHead)
    }

    /// `bytes=a-b` or `bytes=a-`; nil for anything else (suffix ranges are not needed here).
    private static func range(from header: String) -> ClosedRange<Int64>? {
        guard header.hasPrefix("bytes=") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard bounds.count == 2, let a = Int64(bounds[0]) else { return nil }
        let b = bounds[1].isEmpty ? Int64.max : Int64(bounds[1])
        guard let b, b >= a else { return nil }
        return a...b
    }

    private func response(_ status: Int, body: Data, headers: [String], head: Bool = false) -> Data {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      416: "Range Not Satisfiable"][status] ?? "Error"
        var text = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: application/octet-stream\r\n"
        for header in headers { text += header + "\r\n" }
        text += "\r\n"
        var response = Data(text.utf8)
        if !head { response.append(body) }
        return response
    }
}
