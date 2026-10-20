import Foundation
import Testing
@testable import FrameScrubCore

@Suite struct ThrottledByteSourceTests {
    /// Reads all of a 4 MiB file in 256 KiB chunks; returns the seconds it took and the bytes.
    private func readAll(bytesPerSecond: Int) throws -> (TimeInterval, [UInt8]) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("throttle-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let content = (0..<4 << 20).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) }
        try Data(content).write(to: url)
        let source = ThrottledByteSource(try FileByteSource(url: url), bytesPerSecond: bytesPerSecond)
        #expect(source.size == Int64(content.count))
        var result = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 256 << 10)
        let start = Date()
        while true {
            let n = try chunk.withUnsafeMutableBytes { try source.read(at: Int64(result.count), count: $0.count, into: $0.baseAddress!) }
            if n == 0 { break }
            result += chunk[..<n]
        }
        return (Date().timeIntervalSince(start), result)
    }

    @Test func limitsRate() throws {
        let (elapsed, bytes) = try readAll(bytesPerSecond: 40_000_000)
        #expect(elapsed >= 0.09)
        #expect(bytes.count == 4 << 20)
        #expect(bytes == (0..<4 << 20).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8) })
        let (free, freeBytes) = try readAll(bytesPerSecond: 0)
        #expect(free < 0.05)
        #expect(freeBytes == bytes)
    }

    /// Credit saved while idle is capped at 0.5 s: after a 0.8 s pause, 1 MB at 1 MB/s still takes ~0.5 s, not ~0.2 s.
    @Test func idleCreditIsCapped() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("throttle-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(count: 1_010_000).write(to: url)
        let source = ThrottledByteSource(try FileByteSource(url: url), bytesPerSecond: 1_000_000)
        var chunk = [UInt8](repeating: 0, count: 1_000_000)
        _ = try chunk.withUnsafeMutableBytes { try source.read(at: 0, count: 10_000, into: $0.baseAddress!) }
        Thread.sleep(forTimeInterval: 0.8)
        let start = Date()
        _ = try chunk.withUnsafeMutableBytes { try source.read(at: 10_000, count: 1_000_000, into: $0.baseAddress!) }
        #expect(Date().timeIntervalSince(start) >= 0.4)
    }
}
