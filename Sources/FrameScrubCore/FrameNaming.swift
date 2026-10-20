import Foundation

/// Expands frame directory / file-name templates. Placeholders: `%{video-dir}`, `%{video-name}`,
/// `%{frame}` or `%{frame:06}` (zero-padded), `%{time}` or `%{time:hh-mm-ss.mmm}` (the third
/// character of the argument is the separator); clip names also take `%{start}` and `%{end}`, formatted like
/// `%{time}`. Unknown placeholders are left as they are.
public struct FrameNaming: Sendable {
    public var directoryTemplate: String
    public var fileTemplate: String

    public static let defaultFallbackRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures/FrameScrub", isDirectory: true)

    private static let placeholder = try! NSRegularExpression(pattern: "%\\{([a-z-]+)(?::([^}]*))?\\}")

    public init(directoryTemplate: String, fileTemplate: String) {
        self.directoryTemplate = directoryTemplate
        self.fileTemplate = fileTemplate
    }

    public func directory(forVideo video: URL) -> URL {
        let path = expand(directoryTemplate, video: video, frame: 0, seconds: 0)
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    public func fileName(forVideo video: URL, frame: Int, seconds: Double, format: ImageFormat, scale: Int = 1) -> String {
        fileName(forVideo: video, frame: frame, seconds: seconds, format: format, suffix: scale > 1 ? "_x\(scale)" : "")
    }

    public func fileName(forVideo video: URL, frame: Int, seconds: Double, format: ImageFormat, suffix: String) -> String {
        expand(fileTemplate, video: video, frame: frame, seconds: seconds) + suffix + "." + format.fileExtension
    }

    /// The name of an A-B clip: `%{start}` and `%{end}` are the clip's first and last second, `%{frame}` and
    /// `%{time}` those of `frame` / `seconds` (the A frame).
    public static func clipFileName(forVideo video: URL, startSeconds: Double, endSeconds: Double, frame: Int,
                                    seconds: Double, template: String, fileExtension: String) -> String {
        FrameNaming(directoryTemplate: "", fileTemplate: template)
            .expand(template, video: video, frame: frame, seconds: seconds, clip: (startSeconds, endSeconds))
            + "." + fileExtension
    }

    public static func fallbackDirectory(forVideo video: URL, root: URL) -> URL {
        root.appendingPathComponent(video.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    public static func timecode(_ seconds: Double, separator: String = ":") -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
        let millis = String(ms % 1000)
        return two(ms / 3_600_000) + separator + two(ms / 60_000 % 60) + separator + two(ms / 1000 % 60)
            + "." + String(repeating: "0", count: 3 - millis.count) + millis
    }

    func expand(_ template: String, video: URL, frame: Int, seconds: Double, clip: (start: Double, end: Double)? = nil) -> String {
        let ns = template as NSString
        var result = ""
        var cursor = 0
        for match in Self.placeholder.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let name = ns.substring(with: match.range(at: 1))
            let argument = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            result += value(of: name, argument: argument, video: video, frame: frame, seconds: seconds, clip: clip)
                ?? ns.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return result + ns.substring(from: cursor)
    }

    private func value(of name: String, argument: String?, video: URL, frame: Int, seconds: Double, clip: (start: Double, end: Double)?) -> String? {
        switch name {
        case "video-dir":
            return video.deletingLastPathComponent().path
        case "video-name":
            return video.deletingPathExtension().lastPathComponent
        case "frame":
            let width = argument.flatMap { Int($0) } ?? 0
            let digits = String(frame)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        case "time":
            return Self.timecode(seconds, separator: Self.separator(of: argument))
        case "start":
            return clip.map { Self.timecode($0.start, separator: Self.separator(of: argument)) }
        case "end":
            return clip.map { Self.timecode($0.end, separator: Self.separator(of: argument)) }
        default:
            return nil
        }
    }

    private static func separator(of argument: String?) -> String {
        argument.flatMap { $0.count >= 3 ? String(Array($0)[2]) : nil } ?? "-"
    }
}
