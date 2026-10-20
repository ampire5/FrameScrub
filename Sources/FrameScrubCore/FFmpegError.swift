import CFFmpeg
import Foundation

public struct FFmpegError: Error, CustomStringConvertible, LocalizedError {
    public let code: Int32
    public let operation: String

    public init(_ code: Int32, _ operation: String) {
        self.code = code
        self.operation = operation
    }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return "\(operation): \(String(cString: buffer))"
    }

    public var errorDescription: String? { description }
}

/// Throws when an FFmpeg call returns a negative error code; passes the value through otherwise.
@discardableResult
func check(_ code: Int32, _ operation: @autoclosure () -> String) throws -> Int32 {
    if code < 0 { throw FFmpegError(code, operation()) }
    return code
}

public enum FFmpegInfo {
    public static var versionString: String { String(cString: av_version_info()) }
}
