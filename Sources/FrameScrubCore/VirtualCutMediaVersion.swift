import Foundation

/// OpenSubtitles fingerprint, also used by the analysis cache. Only two small reads are needed.
public enum VirtualCutMediaVersion {
    struct Changed: LocalizedError {
        var errorDescription: String? { "This source differs from the file used to make the cut." }
    }

    public static func read(from cache: ReadCache) throws -> String {
        guard cache.fileSize > 0 else { throw Changed() }
        let chunk = Int(min(64 * 1024, cache.fileSize / 8 * 8))
        var bytes = [UInt8](repeating: 0, count: chunk)
        var sum = UInt64(cache.fileSize)
        var cursor = ReadCursor()
        for offset in [0, cache.fileSize - Int64(chunk)] {
            try bytes.withUnsafeMutableBytes { buffer in
                var read = 0
                while read < chunk {
                    let count = try cache.read(at: offset + Int64(read), count: chunk - read,
                                               into: buffer.baseAddress!.advanced(by: read),
                                               cached: false, cursor: &cursor, readAhead: false)
                    guard count > 0 else { throw Changed() }
                    read += count
                }
                for index in stride(from: 0, to: chunk, by: 8) {
                    sum &+= UInt64(littleEndian: buffer.loadUnaligned(fromByteOffset: index, as: UInt64.self))
                }
            }
        }
        return String(format: "%016llx", sum)
    }
}
