import CFFmpeg
import Foundation

/// One demuxer's position over a shared `ReadCache`, exposed to FFmpeg as an `AVIOContext`.
/// Used by one thread at a time (its demuxer's owner).
final class AVIOReader {
    let cache: ReadCache
    let cached: Bool
    /// Whether a run of consecutive blocks makes the cache load the next ones in the background.
    let readAhead: Bool
    /// Index-only reads (spec §2.1): return zeros of the requested length without touching the file.
    var zeroData = false
    private(set) var context: UnsafeMutablePointer<AVIOContext>!
    private var position: Int64 = 0
    private var cursor = ReadCursor()

    /// Cached readers take small reads (blocks do the batching); an uncached one (the index scan) reads a whole
    /// block's worth at a time, or every 64 KiB would pay the network's latency.
    init(cache: ReadCache, cached: Bool, readAhead: Bool = true) throws {
        self.cache = cache
        self.readAhead = readAhead
        self.cached = cached
        let bufferSize = Int32(cached ? 64 << 10 : ReadCache.blockSize)
        guard let buffer = av_malloc(Int(bufferSize)) else { throw FFmpegError(-1, "allocate I/O buffer") }
        guard let context = avio_alloc_context(buffer.assumingMemoryBound(to: UInt8.self), bufferSize, 0, nil,
                                               avioRead, nil, avioSeek) else {
            av_free(buffer)
            throw FFmpegError(-1, "allocate I/O context")
        }
        self.context = context
        context.pointee.opaque = Unmanaged.passUnretained(self).toOpaque()
    }

    deinit {
        av_freep(&context.pointee.buffer)   // FFmpeg may have replaced the buffer it was given
        var c: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&c)
    }

    fileprivate func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) -> Int32 {
        guard position < cache.fileSize else { return cff_error_eof() }
        let n = Int(min(Int64(count), cache.fileSize - position))
        if zeroData {
            buffer.initialize(repeating: 0, count: n)
            position += Int64(n)
            return Int32(n)
        }
        do {
            let got = try cache.read(at: position, count: n, into: buffer, cached: cached, cursor: &cursor, readAhead: readAhead)
            guard got > 0 else { return cff_error_eof() }
            position += Int64(got)
            return Int32(got)
        } catch {
            return cff_error_eio()
        }
    }

    fileprivate func seek(_ offset: Int64, whence: Int32) -> Int64 {
        switch whence & ~AVSEEK_FORCE {
        case AVSEEK_SIZE: return cache.fileSize
        case SEEK_SET: position = offset
        case SEEK_CUR: position += offset
        case SEEK_END: position = cache.fileSize + offset
        default: return -1
        }
        return position
    }
}

private func avioRead(_ opaque: UnsafeMutableRawPointer?, _ buffer: UnsafeMutablePointer<UInt8>?, _ size: Int32) -> Int32 {
    Unmanaged<AVIOReader>.fromOpaque(opaque!).takeUnretainedValue().read(into: buffer!, count: Int(size))
}

private func avioSeek(_ opaque: UnsafeMutableRawPointer?, _ offset: Int64, _ whence: Int32) -> Int64 {
    Unmanaged<AVIOReader>.fromOpaque(opaque!).takeUnretainedValue().seek(offset, whence: whence)
}
