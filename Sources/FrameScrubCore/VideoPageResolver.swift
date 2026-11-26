import Darwin
import Foundation

public struct ResolvedVideo: Sendable {
    public struct Track: Sendable {
        let url: URL
        let headers: [String: String]
    }

    public struct Format: Sendable, Equatable {
        public let id: String?
        public let width: Int?
        public let height: Int?
        public let fps: Double?
        public let codec: String?
        public let videoBitrateKbps: Double?
    }

    public let title: String
    public let itemID: String?
    public let selectedFormat: Format?
    let video: Track
    let audio: Track?

    init(title: String, video: Track, audio: Track?, itemID: String? = nil, selectedFormat: Format? = nil) {
        self.title = title
        self.itemID = itemID
        self.selectedFormat = selectedFormat
        self.video = video
        self.audio = audio
    }
}

public enum VideoPageResolver {
    public enum Failure: LocalizedError, Equatable {
        case unavailable, signInRequired, unsupported, noVideo, timedOut, outputLimit

        public var errorDescription: String? {
            switch self {
            case .unavailable: "Install yt-dlp or gallery-dl to open links to video pages."
            case .signInRequired: "The video page requires sign-in. Open it in your browser."
            case .unsupported: "The installed extractors do not support this video page. Try updating yt-dlp or gallery-dl."
            case .noVideo: "The extractors found no playable video on this page. Try updating yt-dlp or gallery-dl."
            case .timedOut: "The video page took too long to respond."
            case .outputLimit: "The video page returned too many results."
            }
        }

        // A later fallback can succeed, but its generic error should not hide an actionable result.
        fileprivate var priority: Int {
            switch self {
            case .unavailable: 0
            case .unsupported: 1
            case .noVideo: 2
            case .outputLimit: 3
            case .timedOut: 4
            case .signInRequired: 5
            }
        }
    }

    public static func isDirectMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "m3u8" || Playlist.videoExtensions.contains(ext)
    }

    /// Run off the main thread. Each extractor has its own deadline and sends only metadata to stdout.
    public static func resolve(_ page: URL, preferBitrate: Bool, cancellation: OpenCancellation) throws -> [ResolvedVideo] {
        guard ByteSources.isRemote(page), page.host != nil else { throw Failure.unsupported }
        let ordering = preferBitrate ? ["--format-sort-force", "--format-sort", "res,fps,vbr"] : []
        let tools: [(String, [String], (Data) throws -> [ResolvedVideo])] = [
            ("yt-dlp", ["--ignore-config", "--simulate", "--playlist-end", "20", "--socket-timeout", "8",
                        "--retries", "0", "--extractor-retries", "0"] + ordering + [
                        "-f", "bv*[protocol^=http][protocol!*=dash]+ba[protocol^=http][protocol!*=dash]/b[protocol=http]/b[protocol=https]/b[protocol^=m3u8]",
                        "--print", "%(.{id,extractor,extractor_key,title,webpage_url,playlist_webpage_url,url,vcodec,acodec,requested_formats,http_headers,is_live,format_id,width,height,fps,vbr})j"], ytDLPItems),
            ("gallery-dl", ["--config-ignore", "--resolve-json", "--range", "1-40",
                            "--post-range", "1-20", "--child-range", "1-20"], galleryDLItems),
        ]
        var failure = Failure.unavailable
        for (name, arguments, parse) in tools {
            try cancellation.check()
            guard let executable = executable(named: name) else { continue }
            do {
                let (data, diagnostic) = try run(executable, arguments + ["--", page.absoluteString], cancellation: cancellation)
                let items: [ResolvedVideo]
                do {
                    items = try parse(data)
                } catch let error as Failure {
                    // gallery-dl may report errors as structured JSON and write no stderr.
                    if let diagnostic, diagnostic.priority > error.priority { throw diagnostic }
                    throw error
                } catch {
                    throw diagnostic ?? .noVideo
                }
                try cancellation.check()
                if !items.isEmpty { return items }
                throw diagnostic ?? .noVideo
            } catch let error as Failure {
                if error.priority > failure.priority { failure = error }
            } catch {
                try cancellation.check()
            }
        }
        throw failure
    }

    private struct Selection: Decodable {
        private enum CodingKeys: String, CodingKey {
            case id, extractor, extractor_key, title, webpage_url, playlist_webpage_url, url, vcodec, acodec
            case requested_formats, http_headers, is_live, format_id, width, height, fps, vbr
        }

        let id: String?
        let extractor: String?
        let extractor_key: String?
        let title: String?
        let webpage_url: String?
        let playlist_webpage_url: String?
        let url: String?
        let vcodec: String?
        let acodec: String?
        let requested_formats: [Selection]?
        let http_headers: [String: String]?
        let is_live: Bool?
        let format_id: String?
        let width: Int?
        let height: Int?
        let fps: Double?
        let vbr: Double?

        init(from decoder: any Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            title = try fields.decodeIfPresent(String.self, forKey: .title)
            url = try fields.decodeIfPresent(String.self, forKey: .url)
            vcodec = try fields.decodeIfPresent(String.self, forKey: .vcodec)
            acodec = try fields.decodeIfPresent(String.self, forKey: .acodec)
            requested_formats = try fields.decodeIfPresent([Selection].self, forKey: .requested_formats)
            http_headers = try fields.decodeIfPresent([String: String].self, forKey: .http_headers)
            is_live = try fields.decodeIfPresent(Bool.self, forKey: .is_live)

            // Extra metadata is optional even when a tool returns it in an unexpected type.
            id = try? fields.decodeIfPresent(String.self, forKey: .id)
            extractor = try? fields.decodeIfPresent(String.self, forKey: .extractor)
            extractor_key = try? fields.decodeIfPresent(String.self, forKey: .extractor_key)
            webpage_url = try? fields.decodeIfPresent(String.self, forKey: .webpage_url)
            playlist_webpage_url = try? fields.decodeIfPresent(String.self, forKey: .playlist_webpage_url)
            format_id = try? fields.decodeIfPresent(String.self, forKey: .format_id)
            width = try? fields.decodeIfPresent(Int.self, forKey: .width)
            height = try? fields.decodeIfPresent(Int.self, forKey: .height)
            fps = try? fields.decodeIfPresent(Double.self, forKey: .fps)
            vbr = try? fields.decodeIfPresent(Double.self, forKey: .vbr)
        }
    }

    static func ytDLPItems(_ data: Data) -> [ResolvedVideo] {
        let decoder = JSONDecoder()
        return data.split(separator: 10).prefix(20).compactMap { line in
            guard let item = try? decoder.decode(Selection.self, from: Data(line)), item.is_live != true else { return nil }
            let tracks = item.requested_formats ?? [item]
            guard let video = tracks.first(where: { $0.vcodec != nil && $0.vcodec != "none" }),
                  let videoTrack = track(video.url, headers: item.http_headers, overrides: video.http_headers) else { return nil }
            let audioTrack: ResolvedVideo.Track?
            if video.acodec == "none" {
                guard let audio = tracks.first(where: { $0.vcodec == "none" && $0.acodec != nil && $0.acodec != "none" }),
                      let selected = track(audio.url, headers: item.http_headers, overrides: audio.http_headers) else { return nil }
                audioTrack = selected
            } else {
                audioTrack = nil
            }
            let extractor = nonempty(item.extractor_key) ?? nonempty(item.extractor)
            // The generic extractor can derive its ID from the media filename.
            let extractedID = extractor?.lowercased() == "generic" ? nil : extractorID(for: "yt-dlp", extractor: extractor, id: item.id)
            let collection = item.playlist_webpage_url.flatMap(URL.init(string:))
            let itemID = extractedID ?? pageID(item.webpage_url, excluding: [videoTrack.url, audioTrack?.url], collection: collection)
            let format = ResolvedVideo.Format(id: nonempty(video.format_id), width: positive(video.width),
                                              height: positive(video.height), fps: positive(video.fps),
                                              codec: video.vcodec, videoBitrateKbps: positive(video.vbr))
            return ResolvedVideo(title: item.title ?? videoTrack.url.lastPathComponent, video: videoTrack, audio: audioTrack,
                                 itemID: itemID, selectedFormat: format)
        }
    }

    static func galleryDLItems(_ data: Data) throws -> [ResolvedVideo] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[Any]] else { return [] }
        var seen = Set<URL>()
        var items: [ResolvedVideo] = []
        for row in rows {
            guard row.count == 3, row[0] as? Int == 3, let address = row[1] as? String,
                  let metadata = row[2] as? [String: Any],
                  let item = track(address, headers: metadata["http_headers"] as? [String: String]) else { continue }
            let ext = (metadata["extension"] as? String ?? item.url.pathExtension).lowercased()
            guard (Playlist.videoExtensions.contains(ext) || ext == "m3u8"), seen.insert(item.url).inserted else { continue }
            let title = metadata["filename"] as? String ?? item.url.lastPathComponent
            let mediaID = metadata["media_id"] as? String ?? (metadata["media_id"] as? Int).map(String.init)
            let itemID = extractorID(for: "gallery-dl", extractor: metadata["category"] as? String, id: mediaID)
                ?? pageID(metadata["webpage_url"] as? String, excluding: [item.url])
            let format = ResolvedVideo.Format(id: nonempty(metadata["format_id"] as? String),
                                              width: positive(metadata["width"] as? Int), height: positive(metadata["height"] as? Int),
                                              fps: positive(metadata["fps"] as? Double), codec: nonempty(metadata["vcodec"] as? String),
                                              videoBitrateKbps: positive(metadata["vbr"] as? Double))
            let selected: ResolvedVideo.Format? = format.id == nil && format.width == nil && format.height == nil
                && format.fps == nil && format.codec == nil && format.videoBitrateKbps == nil ? nil : format
            items.append(ResolvedVideo(title: title.isEmpty ? "Video" : title, video: item, audio: nil,
                                       itemID: itemID, selectedFormat: selected))
            if items.count == 20 { break }
        }
        if items.isEmpty {
            let failures = rows.compactMap { row -> Failure? in
                guard row.count == 2, row[0] as? Int == -1, let error = row[1] as? [String: Any] else { return nil }
                switch error["error"] as? String {
                case "AuthRequired", "AuthenticationError": return .signInRequired
                case "NoExtractorError": return .unsupported
                default: return nil
                }
            }
            if let failure = failures.max(by: { $0.priority < $1.priority }) { throw failure }
        }
        // Some gallery extractors attach a shared post URL to every file in a post.
        let identities = Dictionary(grouping: items.compactMap(\.itemID), by: { $0 })
        return items.map { item in
            guard let id = item.itemID, identities[id, default: []].count > 1 else { return item }
            return ResolvedVideo(title: item.title, video: item.video, audio: item.audio, selectedFormat: item.selectedFormat)
        }
    }

    private static func extractorID(for tool: String, extractor: String?, id: String?) -> String? {
        guard let extractor = nonempty(extractor)?.lowercased(), !extractor.contains(":"),
              let id = nonempty(id), !id.contains("://") else { return nil }
        return "\(tool):\(extractor):\(id)"
    }

    private static func pageID(_ address: String?, excluding tracks: [URL?], collection: URL? = nil) -> String? {
        guard let address, address.utf8.count <= 4096, let url = track(address)?.url, !isDirectMedia(url),
              url != collection, !tracks.compactMap({ $0 }).contains(where: { other in
                  other.host?.lowercased() == url.host?.lowercased() && other.port == url.port && other.path == url.path
              }) else { return nil }
        return "page:\(url.absoluteString)"
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              value.utf8.count <= 512, !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return value
    }

    private static func positive<T: Numeric & Comparable>(_ value: T?) -> T? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func track(_ address: String?, headers: [String: String]? = nil,
                              overrides: [String: String]? = nil) -> ResolvedVideo.Track? {
        guard let address, let url = URL(string: address), ByteSources.isRemote(url),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        let allowed = ["user-agent": "User-Agent", "referer": "Referer", "origin": "Origin", "accept": "Accept",
                       "accept-language": "Accept-Language"]
        var selected: [String: String] = [:]
        for fields in [headers ?? [:], overrides ?? [:]] {
            for (key, value) in fields {
                if let field = allowed[key.lowercased()], value.utf8.count <= 4096,
                   !value.contains(where: { $0.isNewline || $0 == "\0" }) {
                    selected[field] = value
                }
            }
        }
        return .init(url: url, headers: selected)
    }

    private static let standardPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    private static var searchPaths: [String] {
        let environment = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return environment.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") } + standardPaths
    }

    private static func executable(named name: String) -> URL? {
        searchPaths.lazy
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func run(_ executable: URL, _ arguments: [String],
                            cancellation: OpenCancellation) throws -> (Data, Failure?) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPaths.joined(separator: ":")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            output.fileHandleForReading.closeFile()
            errors.fileHandleForReading.closeFile()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var descriptors = [output, errors].map {
            pollfd(fd: $0.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        }
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var data = Data()
        let diagnosticLimit = 32 * 1024
        var diagnostic = Data()
        while descriptors.contains(where: { $0.fd >= 0 }) {
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            let ready = poll(&descriptors, nfds_t(descriptors.count), 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw Failure.noVideo }
            if ready == 0 { continue }
            for index in descriptors.indices where descriptors[index].revents != 0 {
                let fd = descriptors[index].fd
                let length = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if length < 0 && errno == EINTR { continue }
                guard length >= 0 else { throw Failure.noVideo }
                if length == 0 {
                    descriptors[index].fd = -1
                } else if index == 0 {
                    guard data.count + length <= 4 * 1024 * 1024 else { throw Failure.outputLimit }
                    data.append(contentsOf: buffer.prefix(length))
                } else {
                    // Keep the final error and continue draining so a full pipe cannot block the child.
                    if diagnostic.count + length > diagnosticLimit {
                        diagnostic.removeFirst(diagnostic.count + length - diagnosticLimit)
                    }
                    diagnostic.append(contentsOf: buffer.prefix(length))
                }
            }
        }
        while process.isRunning {
            try cancellation.check()
            guard ContinuousClock.now < deadline else { throw Failure.timedOut }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Extractors can emit usable entries before reporting a skipped entry.
        return (data, failure(for: diagnostic))
    }

    private static func failure(for diagnostic: Data) -> Failure? {
        let message = String(decoding: diagnostic, as: UTF8.self).lowercased()
        if ["requires login", "login required", "log in to", "sign in to", "sign in is required",
            "authentication required", "authenticationerror", "authrequired"].contains(where: { message.contains($0) }) {
            return .signInRequired
        }
        if ["timed out", "readtimeout", "connecttimeout"].contains(where: { message.contains($0) }) {
            return .timedOut
        }
        if ["unsupported url", "no suitable extractor", "noextractorerror", "no such option",
            "unrecognized arguments"].contains(where: { message.contains($0) }) {
            return .unsupported
        }
        return nil
    }
}
