import Foundation

/// A file served over HTTP, read with Range requests: every `read` is one ranged GET, waited for on the calling
/// thread, its body handed over as it arrives (`read(…, progress:)`). Thread-safe: `URLSession` runs the requests side by side. `headers` go with every request (Stash's
/// `ApiKey`). Opening asks for the first block (`firstRead` bytes, `ReadCache`'s block) and waits only for the answer's
/// headers: the size comes from `Content-Range` (a server that ignores ranges is refused at once instead of failing
/// on the first seek), and the body goes on arriving for the first read, which takes it as it comes. That is one
/// request fewer than asking for byte 0 first (~0.4 s per stream open on a slow server, measured 2026-10-25).
public final class HTTPByteSource: ByteSource, @unchecked Sendable {
    public let size: Int64
    public let url: URL
    public var arrivesGradually: Bool { true }
    private let headers: [String: String]
    private let session: URLSession
    private let lock = NSLock()
    /// The open's answer, until the first read takes it (or passes it by).
    private var opening: OpeningRead?

    /// How long one request may take to answer, and to deliver its bytes (a 2 MiB block over a slow link).
    public static let requestTimeout: TimeInterval = 15
    public static let resourceTimeout: TimeInterval = 120

    /// Throws `FFmpegError` like `avformat_open_input` would ("open stream: Connection refused"): a 404 reads as a
    /// missing file, other statuses and a server without ranges as an I/O error.
    public init(url: URL, headers: [String: String] = [:], session: URLSession? = nil,
                firstRead: Int = ReadCache.blockSize) throws {
        self.url = url
        self.headers = headers
        self.session = session ?? Self.makeSession()
        let name = url.lastPathComponent
        let first = max(1, firstRead)
        let opening = OpeningRead(capacity: first)
        let task = self.session.dataTask(with: Self.request(url, headers: headers, range: 0...Int64(first - 1)))
        task.delegate = opening
        opening.task = task
        task.resume()
        opening.headersArrived.wait()
        guard let response = opening.response else {
            throw Self.failure(opening.error ?? URLError(.badServerResponse), name: name)
        }
        switch response.statusCode {
        case 206:
            if let total = Self.total(fromContentRange: response.value(forHTTPHeaderField: "Content-Range")) {
                size = total
            } else if response.expectedContentLength >= 0, response.expectedContentLength < Int64(first) {
                size = response.expectedContentLength   // no total said, but the whole file fitted in the answer
            } else {
                task.cancel()
                throw FFmpegError(-EIO, "open \(name): no Content-Range in the server's answer")
            }
            self.opening = opening
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
        try read(at: offset, count: count, into: buffer, progress: { _ in true })
    }

    /// One ranged GET whose body is copied into `buffer` as it arrives, reporting each step.
    deinit { opening?.task?.cancel() }

    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
                     progress: @escaping @Sendable (Int) -> Bool) throws -> Int {
        guard offset < size, count > 0 else { return 0 }
        let last = min(offset + Int64(count), size) - 1
        // The first read takes the open's answer when it lies inside it; any other first read lets it go.
        let first = lock.withLock { () -> OpeningRead? in
            defer { opening = nil }
            return opening
        }
        if let first {
            if last < Int64(first.capacity) {
                return try first.take(from: Int(offset), count: Int(last - offset) + 1, into: buffer, progress: progress,
                                      name: url.lastPathComponent)
            }
            first.task?.cancel()
        }
        let sink = BodySink(buffer: buffer, capacity: Int(last - offset) + 1, progress: progress)
        let task = session.dataTask(with: Self.request(url, headers: headers, range: offset...last))
        task.delegate = sink
        task.resume()
        sink.done.wait()
        if sink.stopped { throw POSIXError(.ECANCELED) }
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

    /// A transport failure as an `FFmpegError` with the matching errno.
    fileprivate static func failure(_ error: Error, name: String) -> FFmpegError {
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
/// to the range asked for), only for a 206, and every chunk is reported (a report answered false cancels the
/// request); `done` is signalled when the task ends.
/// The session's delegate queue is serial, and the reader looks at the fields only after `done`.
private final class BodySink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    private let buffer: UnsafeMutableRawPointer
    private let capacity: Int
    private let progress: @Sendable (Int) -> Bool
    private(set) var stopped = false
    private(set) var status = 0
    private(set) var filled = 0
    private(set) var error: Error?

    init(buffer: UnsafeMutableRawPointer, capacity: Int, progress: @escaping @Sendable (Int) -> Bool) {
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
        if !progress(filled) {
            stopped = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // A status other than 206 was cancelled on purpose: that is the status, not a transport failure.
        if let error, !stopped, status == 206 || (error as? URLError)?.code != .cancelled { self.error = error }
        done.signal()
    }
}

/// The open's request (`HTTPByteSource.init`): `headersArrived` is signalled with the answer's headers (or a failure
/// before them); the body of a 206 goes on into its own buffer, and the first read copies from it as it arrives.
private final class OpeningRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let headersArrived = DispatchSemaphore(value: 0)
    let capacity: Int
    weak var task: URLSessionTask?
    private let storage: UnsafeMutableRawPointer
    private let condition = NSCondition()
    private var headersSignalled = false
    private(set) var response: HTTPURLResponse?
    private(set) var error: Error?
    private var arrived = 0
    private var finished = false

    init(capacity: Int) {
        self.capacity = capacity
        storage = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
    }

    deinit { storage.deallocate() }

    private func signalHeaders() {
        guard !headersSignalled else { return }
        headersSignalled = true
        headersArrived.signal()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        condition.withLock { self.response = http }
        completionHandler(http?.statusCode == 206 ? .allow : .cancel)   // another status's body is never read
        condition.withLock { signalHeaders() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.withLock {
            let n = min(data.count, capacity - arrived)
            guard n > 0 else { return }
            data.withUnsafeBytes { storage.advanced(by: arrived).copyMemory(from: $0.baseAddress!, byteCount: n) }
            arrived += n
            condition.broadcast()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        condition.withLock {
            // a status other than 206 was cancelled on purpose: that is the status, not a transport failure
            if let error, (error as? URLError)?.code != .cancelled || response == nil { self.error = error }
            finished = true
            condition.broadcast()
            signalHeaders()
        }
    }

    /// `count` bytes from `start` of the answer into `buffer`, reported as they arrive (false from `progress` stops
    /// the request: `ECANCELED`). Fewer when the answer ends sooner.
    func take(from start: Int, count: Int, into buffer: UnsafeMutableRawPointer,
              progress: @Sendable (Int) -> Bool, name: String) throws -> Int {
        var copied = 0
        while copied < count {
            let (available, done, failure) = condition.withLock { () -> (Int, Bool, Error?) in
                while max(0, min(arrived - start, count)) <= copied, !finished { condition.wait() }
                return (max(0, min(arrived - start, count)), finished, error)
            }
            if available > copied {
                buffer.advanced(by: copied).copyMemory(from: storage.advanced(by: start + copied),
                                                       byteCount: available - copied)
                copied = available
                if !progress(copied) {
                    task?.cancel()
                    throw POSIXError(.ECANCELED)
                }
            }
            if done, available <= copied {
                if let failure, copied < count { throw HTTPByteSource.failure(failure, name: name) }
                break
            }
        }
        return copied
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
