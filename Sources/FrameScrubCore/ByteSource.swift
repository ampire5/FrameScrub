import Foundation

/// Random-access bytes of one file. Implementations are thread-safe.
public protocol ByteSource: AnyObject, Sendable {
    var size: Int64 { get }
    /// Whether a read's bytes arrive over a while (a network answer) rather than at once: `ReadCache` then loads a
    /// block on its own thread and hands readers its bytes as they come.
    var arrivesGradually: Bool { get }
    /// Reads up to `count` bytes at `offset`; returns the number read (0 at end of file).
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int
    /// The same read, calling `progress(n)` (on any thread) whenever the first `n` bytes are in the buffer, so a
    /// reader can use them before the rest arrives; the last report is the number returned. `progress` returning
    /// false stops the read (it throws `ECANCELED`) where the source can stop early.
    func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
              progress: @escaping @Sendable (Int) -> Bool) throws -> Int
}

extension ByteSource {
    public var arrivesGradually: Bool { false }

    /// Reads, then reports once: for a source whose reads arrive whole.
    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer,
                     progress: @escaping @Sendable (Int) -> Bool) throws -> Int {
        let n = try read(at: offset, count: count, into: buffer)
        if n > 0 { _ = progress(n) }
        return n
    }
}

/// A file read with `pread`, which is safe to call from several threads on one descriptor.
public final class FileByteSource: ByteSource {
    public let size: Int64
    private let fd: Int32

    /// Throws `FFmpegError` like `avformat_open_input` would ("open name: No such file or directory").
    public init(url: URL) throws {
        fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FFmpegError(-errno, "open \(url.lastPathComponent)") }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let code = errno
            close(fd)
            throw FFmpegError(-code, "open \(url.lastPathComponent)")
        }
        size = Int64(info.st_size)
    }

    deinit { close(fd) }

    public func read(at offset: Int64, count: Int, into buffer: UnsafeMutableRawPointer) throws -> Int {
        var done = 0
        while done < count {
            let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            done += n
        }
        return done
    }
}
