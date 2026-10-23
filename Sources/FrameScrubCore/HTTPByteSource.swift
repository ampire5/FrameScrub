import Foundation

/// A file served over HTTP, read with Range requests: every `read` is one ranged GET, waited for on the calling
/// thread. Thread-safe: `URLSession` runs the requests side by side. `headers` go with every request (Stash's
/// `ApiKey`). Opening asks for the first byte (`Range: bytes=0-0`) to learn the size from `Content-Range`, so a
/// server that ignores ranges is refused at once instead of failing on the first seek.
public final class HTTPByteSource: ByteSource, @unchecked Sendable {
    public let size: Int64
    public let url: URL
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
        guard offset < size, count > 0 else { return 0 }
        let last = min(offset + Int64(count), size) - 1
        let (response, data) = try Self.perform(Self.request(url, headers: headers, range: offset...last),
                                                with: session, name: url.lastPathComponent)
        guard response.statusCode == 206 else {
            if response.statusCode == 416 { return 0 }
            throw POSIXError(.EIO)
        }
        let n = min(data.count, Int(last - offset) + 1)
        guard n > 0 else { return 0 }
        data.withUnsafeBytes { buffer.copyMemory(from: $0.baseAddress!, byteCount: n) }
        return n
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
        } catch let error as URLError {
            throw FFmpegError(code(for: error), "open \(name): \(error.localizedDescription)")
        } catch {
            throw FFmpegError(-EIO, "open \(name): \(error.localizedDescription)")
        }
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

public enum ByteSources {
    /// Whether `url` is read over HTTP (`http` or `https`) rather than from the file system.
    public static func isRemote(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }

    /// The source for `url`: the file itself, or `HTTPByteSource` for an `http(s)` URL (`headers` go with its requests).
    public static func open(_ url: URL, headers: [String: String] = [:]) throws -> any ByteSource {
        isRemote(url) ? try HTTPByteSource(url: url, headers: headers) : try FileByteSource(url: url)
    }
}
