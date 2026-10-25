import Foundation

/// A file served over HTTP, read with Range requests: every `read` is one ranged GET, waited for on the calling
/// thread, its body handed over as it arrives (`read(…, progress:)`). Thread-safe: `URLSession` runs the requests side by side. `headers` go with every request (Stash's
/// `ApiKey`). Opening asks for the first byte (`Range: bytes=0-0`) to learn the size from `Content-Range`, so a
/// server that ignores ranges is refused at once instead of failing on the first seek.
public final class HTTPByteSource: ByteSource, @unchecked Sendable {
    public let size: Int64
    public let url: URL
    public var arrivesGradually: Bool { true }
    private let headers: [String: String]
    private let session: URLSession

    /// How long one request may take to answer, and to deliver its bytes (a 2 MiB block over a slow link).
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 120

    /// Throws `FFmpegError` like `avformat_open_input` would ("open stream: Connection refused"): a 404 reads as a
    /// missing file, other statuses and a server without ranges as an I/O error.
    public init(url: URL, headers: [String: String] = [:], session: URLSession? = nil) throws {
        self.url = url
        self.headers = headers
        self.session = session ?? Self.makeSession()
        let name = url.lastPathComponent
        let (response, _) = try Self.perform(Self.request(url, headers: headers, range: 0...0), with: self.session,
                                             name: name)
        switch response.statusCode {
        case 206:
            guard let total = Self.total(fromContentRange: response.value(forHTTPHeaderField: "Content-Range")) else {
                throw FFmpegError(-EIO, "open \(name): no Content-Range in the server's answer")
            }
            size = total
        case 200:
            // No range support; a server that reports the length may still mean an empty file.
            guard response.expectedContentLength == 0 else {
                throw FFmpegError(-EIO, "open \(name): the server does not support Range requests")
            }
            size = 0
        case 416:
            size = 0   // nothing to read from an empty file
        default:
            throw FFmpegError(Self.code(forStatus: response.statusCode), "open \(name): HTTP \(response.statusCode)")
        }
    }

    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        try read(at: offset, count: count, into: buffer, progress: { _ in })
    }

    /// One ranged GET whose body is copied into `buffer` as it arrives, reporting each step.
    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
                     progress: @escaping @Sendable (Int) -> Void) throws -> Int {
        guard offset < size, count > 0 else { return 0 }
        let last = min(offset + Int64(count), size) - 1
        let sink = BodySink(buffer: buffer, capacity: Int(last - offset) + 1, progress: progress)
        let task = session.dataTask(with: Self.request(url, headers: headers, range: offset...last))
        task.delegate = sink
        task.resume()
        sink.done.wait()
        if let error = sink.error { throw Self.failure(error, name: url.lastPathComponent) }
        guard sink.status == 206 else {
            if sink.status == 416 { return 0 }
            throw POSIXError(.EIO)
        }
        return sink.filled
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        return URLSession(configuration: configuration)
    }

    private static func request(_ url: URL, headers: [String: String], range: ClosedRange<Int64>) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // compressed bytes have no offsets
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// One request, waited for; a transport failure is an `FFmpegError` with the matching errno.
    private static func perform(_ request: URLRequest, with session: URLSession,
                                name: String) throws -> (HTTPURLResponse, Data) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(HTTPURLResponse, Data), Error> = .failure(URLError(.unknown))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let response = response as? HTTPURLResponse {
                result = .success((response, data ?? Data()))
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            done.signal()
        }
        task.resume()
        done.wait()
        do {
            return try result.get()
        } catch {
            throw failure(error, name: name)
        }
    }

    /// A transport failure as an `FFmpegError` with the matching errno.
    private static func failure(_ error: Error, name: String) -> FFmpegError {
        guard let error = error as? URLError else { return FFmpegError(-EIO, "open \(name): \(error.localizedDescription)") }
        return FFmpegError(code(for: error), "open \(name): \(error.localizedDescription)")
    }

    /// `bytes 0-0/12345` → 12345; nil for an unknown total (`*`) or another shape.
    static func total(fromContentRange header: String?) -> Int64? {
        guard let header, let slash = header.lastIndex(of: "/") else { return nil }
        return Int64(header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    /// The errno `OpenFailure` reads a status as.
    private static func code(forStatus status: Int) -> Int32 {
        switch status {
        case 404, 410: -ENOENT
        case 401, 403: -EACCES
        default: -EIO
        }
    }

    private static func code(for error: URLError) -> Int32 {
        switch error.code {
        case .timedOut: -ETIMEDOUT
        case .cannotFindHost, .dnsLookupFailed: -EHOSTUNREACH
        case .cannotConnectToHost: -ECONNREFUSED
        case .notConnectedToInternet, .networkConnectionLost: -ENETDOWN
        default: -EIO
        }
    }
}

/// Receives one ranged response for `HTTPByteSource.read`: the body goes straight into the reader's buffer (clipped
/// to the range asked for), only for a 206, and every chunk is reported; `done` is signalled when the task ends.
/// The session's delegate queue is serial, and the reader looks at the fields only after `done`.
private final class BodySink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private let progress: @Sendable (Int) -> Void
    private(set) var status = 0
    private(set) var filled = 0
    private(set) var error: Error?

    init(buffer: UnsafeMutableRawPointer, capacity: Int, progress: @escaping @Sendable (Int) -> Void) {
        self.buffer = buffer
        self.capacity = capacity
        self.progress = progress
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(status == 206 ? .allow : .cancel)   // another status's body is never read
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let n = min(data.count, capacity - filled)
        guard n > 0 else { return }
        data.withUnsafeBytes { buffer.advanced(by: filled).copyMemory(from: $0.baseAddress!, byteCount: n) }
        filled += n
        progress(filled)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A status other than 206 was cancelled on purpose: that is the status, not a transport failure.
        if let error, status == 206 || (error as? URLError)?.code != .cancelled { self.error = error }
        done.signal()
    }
}

public enum ByteSources {
    /// Whether `url` is read over HTTP (`http` or `https`) rather than from the file system.
    public static func isRemote(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// The source for `url`: the file itself, or `HTTPByteSource` for an `http(s)` URL (`headers` go with its requests).
    public static func open(_ url: URL, headers: [String: String] = [:]) throws -> any ByteSource {
        isRemote(url) ? try HTTPByteSource(url: url, headers: headers) : try FileByteSource(url: url)
    }
}
