import CoreGraphics
import Foundation
import ImageIO

/// A scene's generated Stash thumbnails. The sheet and cue index live only with its filmstrip loader.
public struct StashStoryboard: Sendable {
    private let index: Index
    private let sheet: CGImage

    init(index: Index, sheet: CGImage) {
        self.index = index
        self.sheet = sheet
    }

    @concurrent public func image(at seconds: Double, fitting pixels: Int) async -> CGImage? {
        guard !Task.isCancelled, let rectangle = index.rectangle(at: seconds),
              CGRect(x: 0, y: 0, width: sheet.width, height: sheet.height).contains(rectangle),
              let tile = sheet.cropping(to: rectangle) else { return nil }
        let scale = min(1, Double(max(1, pixels)) / Double(max(tile.width, tile.height)))
        let width = max(1, Int((Double(tile.width) * scale).rounded()))
        let height = max(1, Int((Double(tile.height) * scale).rounded()))
        // Give the thumbnail its own backing so caching a tile does not retain the much larger sheet.
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(tile, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    struct Index: Sendable {
        private struct Cue: Sendable {
            let start: Double
            let end: Double
            let rectangle: CGRect
        }

        private let cues: [Cue]

        init?(_ text: String) {
            let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            guard let header = lines.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")),
                  header == "WEBVTT" || header.hasPrefix("WEBVTT ") || header.hasPrefix("WEBVTT\t") else { return nil }
            var parsed: [Cue] = []
            for i in lines.indices.dropLast() {
                let times = lines[i].components(separatedBy: "-->")
                guard times.count == 2, let start = Self.timestamp(times[0][...]),
                      let endStamp = times[1].split(whereSeparator: \.isWhitespace).first,
                      let end = Self.timestamp(endStamp), start < end,
                      let rectangle = Self.rectangle(lines[i + 1]) else { continue }
                parsed.append(Cue(start: start, end: end, rectangle: rectangle))
            }
            parsed.sort { $0.start < $1.start }
            guard !parsed.isEmpty, zip(parsed, parsed.dropFirst()).allSatisfy({ $0.end <= $1.start }) else { return nil }
            cues = parsed
        }

        func rectangle(at seconds: Double) -> CGRect? {
            guard seconds.isFinite else { return nil }
            var low = 0, high = cues.count
            while low < high {
                let middle = low + (high - low) / 2
                if seconds < cues[middle].start { high = middle }
                else { low = middle + 1 }
            }
            guard low > 0, seconds < cues[low - 1].end else { return nil }
            return cues[low - 1].rectangle
        }

        private static func timestamp(_ stamp: Substring) -> Double? {
            let parts = stamp.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 || parts.count == 3,
                  let minutes = Int(parts[parts.count - 2]), (0..<60).contains(minutes),
                  let seconds = Double(parts[parts.count - 1]), (0..<60).contains(seconds) else { return nil }
            let hours = parts.count == 3 ? Int(parts[0]) : 0
            guard let hours, hours >= 0 else { return nil }
            return Double(hours) * 3600 + Double(minutes) * 60 + seconds
        }

        private static func rectangle(_ payload: Substring) -> CGRect? {
            // The GraphQL sprite endpoint serves the sheet. The cue's filename is never requested.
            let parts = payload.trimmingCharacters(in: .whitespaces).components(separatedBy: "#xywh=")
            guard parts.count == 2 else { return nil }
            let fields = parts[1].split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4 else { return nil }
            let coordinates = fields.compactMap { Int($0) }
            guard coordinates.count == 4, coordinates[0] >= 0, coordinates[1] >= 0,
                  coordinates[2] > 0, coordinates[3] > 0 else { return nil }
            return CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
        }
    }

    struct Origin: Equatable, Sendable {
        let scheme: String
        let host: String
        let port: Int

        init?(_ url: URL) {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = components.host?.lowercased(), !host.isEmpty,
                  components.user == nil, components.password == nil else { return nil }
            self.scheme = scheme
            self.host = host
            port = components.port ?? (scheme == "https" ? 443 : 80)
        }

        func asset(_ path: String, relativeTo base: URL) -> URL? {
            guard !path.isEmpty, let url = URL(string: path, relativeTo: base.appendingPathComponent(""))?.absoluteURL,
                  Self(url) == self else { return nil }
            return url
        }
    }

    public struct Source: Sendable {
        private let base: URL
        private let origin: Origin
        private let apiKey: String?
        private let sceneID: String

        public init?(base: URL, apiKey: String, sceneID: String) {
            guard let origin = Origin(base) else { return nil }
            self.base = base
            self.origin = origin
            self.apiKey = apiKey.isEmpty ? nil : apiKey
            self.sceneID = sceneID
        }

        private struct Response: Decodable {
            let data: DataFields?

            struct DataFields: Decodable {
                let findScene: Scene?

                struct Scene: Decodable {
                    let paths: Paths?

                    struct Paths: Decodable {
                        let vtt: String?
                        let sprite: String?
                    }
                }
            }
        }

        @concurrent public func load() async throws -> StashStoryboard {
            let body = try JSONSerialization.data(withJSONObject: [
                "query": "query($id: ID!) { findScene(id: $id) { paths { vtt sprite } } }",
                "variables": ["id": sceneID]
            ])
            let manifest = try await data(base.appendingPathComponent("graphql"), limit: 64 * 1024, body: body)
            let paths = try JSONDecoder().decode(Response.self, from: manifest).data?.findScene?.paths
            guard let vttPath = paths?.vtt, let vttURL = origin.asset(vttPath, relativeTo: base),
                  let spritePath = paths?.sprite, let spriteURL = origin.asset(spritePath, relativeTo: base) else {
                throw Failure.unavailable
            }
            let vtt = try await data(vttURL, limit: 512 * 1024)
            guard let text = String(data: vtt, encoding: .utf8), let index = Index(text) else { throw Failure.unavailable }
            let bytes = try await data(spriteURL, limit: 8 * 1024 * 1024)
            try Task.checkCancellation()
            guard let imageSource = CGImageSourceCreateWithData(bytes as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= (16 * 1024 * 1024) / height,
                  let sheet = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { throw Failure.unavailable }
            return StashStoryboard(index: index, sheet: sheet)
        }

        private enum Failure: Error { case unavailable }

        private final class RejectRedirects: NSObject, URLSessionTaskDelegate {
            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                            completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
                completionHandler(nil)
            }
        }

        private static let session: URLSession = {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 12
            config.httpShouldSetCookies = false
            config.urlCache = nil
            return URLSession(configuration: config, delegate: RejectRedirects(), delegateQueue: nil)
        }()

        private func data(_ url: URL, limit: Int, body: Data? = nil) async throws -> Data {
            try Task.checkCancellation()
            guard Origin(url) == origin else { throw Failure.unavailable }
            var request = URLRequest(url: url, timeoutInterval: 5)
            if let apiKey { request.setValue(apiKey, forHTTPHeaderField: "ApiKey") }
            if let body {
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (stream, response) = try await Self.session.bytes(for: request)
            defer { stream.task.cancel() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  response.expectedContentLength <= Int64(limit) else { throw Failure.unavailable }
            var data = Data()
            if response.expectedContentLength > 0 { data.reserveCapacity(Int(response.expectedContentLength)) }
            for try await byte in stream {
                guard data.count < limit else { throw Failure.unavailable }
                data.append(byte)
            }
            return data
        }
    }
}
