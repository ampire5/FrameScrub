import CFFmpeg
import Foundation
import os

/// The lifetime shared by the open, video and audio readers for one HLS item.
public final class HLSMediaSession: Sendable {
    private let cancellation = CancellationFlag()
    // Set by the preparation worker before any demuxers open, then shared by the session's readers.
    var requestHeaders: String? {
        get { headers.withLock { $0 } }
        set { headers.withLock { $0 = newValue } }
    }
    private let headers = OSAllocatedUnfairLock<String?>(initialState: nil)
    fileprivate let segments = HLSSegmentCache()

    var isCancelled: Bool { cancellation.isCancelled }
    func cancel() {
        cancellation.cancel()
        segments.clear()
    }

    func segment(for url: String) -> Data? { segments.take(url) }
    func remember(_ data: Data, for url: String) { segments.store(data, for: url) }
    func reserveSegmentIO(_ bytes: Int) -> Bool { segments.reserve(bytes) }
    func releaseSegmentIO(_ bytes: Int) { segments.release(bytes) }
}

private final class HLSSegmentCache: Sendable {
    private struct Entries {
        var data: [String: Data] = [:]
        var oldestFirst: [String] = []
        var bytes = 0
        var openBytes = 0
        var openCount = 0
        var closed = false
    }

    // Encoded data has a separate ceiling from decoded IOSurfaces. The 640x360 jump fixture
    // uses ~100 KiB per segment. Oversize resources keep the streaming path and never allocate a copy.
    private static let byteLimit = 32 << 20
    private static let entryLimit = 64
    private let entries = OSAllocatedUnfairLock(initialState: Entries())

    func take(_ url: String) -> Data? {
        entries.withLock { state in
            guard let data = state.data[url] else { return nil }
            state.oldestFirst.removeAll { $0 == url }
            state.oldestFirst.append(url)
            return data
        }
    }

    func store(_ data: Data, for url: String) {
        entries.withLock { state in
            guard !state.closed, state.data[url] == nil, data.count <= Self.byteLimit else { return }
            while state.bytes + data.count > Self.byteLimit || state.data.count >= Self.entryLimit {
                let removed = state.oldestFirst.removeFirst()
                state.bytes -= state.data.removeValue(forKey: removed)?.count ?? 0
            }
            state.data[url] = data
            state.oldestFirst.append(url)
            state.bytes += data.count
        }
    }

    // Master playlists can open multiple renditions, including when parallel HTTP is off.
    // Budget live recordings and pinned replays together, independently of the LRU.
    func reserve(_ bytes: Int) -> Bool {
        entries.withLock { state in
            guard !state.closed, state.openBytes + bytes <= 16 << 20, state.openCount < 8 else { return false }
            state.openBytes += bytes
            state.openCount += 1
            return true
        }
    }

    func release(_ bytes: Int) {
        entries.withLock {
            $0.openBytes -= bytes
            $0.openCount -= 1
        }
    }

    func clear() {
        entries.withLock { state in
            state.closed = true
            state.data.removeAll()
            state.oldestFirst.removeAll()
            state.bytes = 0
        }
    }
}

/// One FFmpeg segment input, either replaying a completed response or recording a sequential
/// native HTTP read. Reads on a miss stream through immediately, including during probing.
final class HLSSegmentIO {
    static let maximumBytes = 8 << 20
    private let session: HLSMediaSession
    private let interrupt: HLSReadInterrupt?
    private let url: String
    private let length: Int64
    private var native: UnsafeMutablePointer<AVIOContext>?
    private var bytes: Data?
    private var position: Int64 = 0

    init(session: HLSMediaSession, interrupt: HLSReadInterrupt?, url: String,
         length: Int64, native: UnsafeMutablePointer<AVIOContext>?, bytes: Data) {
        self.session = session
        self.interrupt = interrupt
        self.url = url
        self.length = length
        self.native = native
        self.bytes = bytes
    }

    deinit { session.releaseSegmentIO(Int(length)) }

    func makeContext() -> UnsafeMutablePointer<AVIOContext>? {
        let capacity: Int32 = 32 << 10
        guard let buffer = av_malloc(Int(capacity))?.assumingMemoryBound(to: UInt8.self) else { return nil }
        guard let context = avio_alloc_context(buffer, capacity, 0, Unmanaged.passUnretained(self).toOpaque(),
            { opaque, target, count in
                guard let opaque, let target else { return -EINVAL }
                return Unmanaged<HLSSegmentIO>.fromOpaque(opaque).takeUnretainedValue().read(target, count: count)
            }, nil, { opaque, offset, whence in
                guard let opaque else { return Int64(-EINVAL) }
                return Unmanaged<HLSSegmentIO>.fromOpaque(opaque).takeUnretainedValue().seek(offset, whence: whence)
            }) else {
            av_free(buffer)
            return nil
        }
        if let native { context.pointee.seekable = native.pointee.seekable }
        return context
    }

    func close(_ context: UnsafeMutablePointer<AVIOContext>) -> Int32 {
        av_free(context.pointee.buffer)
        var wrapped: UnsafeMutablePointer<AVIOContext>? = context
        avio_context_free(&wrapped)
        return avio_closep(&native)
    }

    private func read(_ target: UnsafeMutablePointer<UInt8>, count: Int32) -> Int32 {
        guard !session.isCancelled, interrupt?.isCancelled != true else { return -EINTR }
        if let native {
            let read = avio_read_partial(native, target, count)
            guard read > 0 else { bytes = nil; return read }
            position += Int64(read)
            if position > length { bytes = nil }
            bytes?.append(target, count: Int(read))
            if position == length, let complete = bytes {
                if !complete.starts(with: "#EXTM3U".utf8) { session.remember(complete, for: url) }
                bytes = nil
            }
            return read
        }
        guard let bytes, position < length else { return cff_error_eof() }
        let found = Int(min(length - position, Int64(count)))
        bytes.withUnsafeBytes { source in
            target.update(from: source.bindMemory(to: UInt8.self).baseAddress! + Int(position), count: found)
        }
        position += Int64(found)
        return Int32(found)
    }

    private func seek(_ offset: Int64, whence: Int32) -> Int64 {
        if whence == AVSEEK_SIZE { return length }
        if let native {
            let result = avio_seek(native, offset, whence)
            if result >= 0, result != position { bytes = nil; position = result }
            return result
        }
        let base: Int64
        switch whence & ~AVSEEK_FORCE {
        case SEEK_SET: base = 0
        case SEEK_CUR: base = position
        case SEEK_END: base = length
        default: return Int64(-EINVAL)
        }
        let (next, overflow) = base.addingReportingOverflow(offset)
        guard !overflow, next >= 0, next <= length else { return Int64(-EINVAL) }
        position = next
        return next
    }
}
