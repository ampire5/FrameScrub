import AppKit
import FrameScrubCore
import HomeScreenKit
import HomeScreenModel
import ImageIO

/// Lives with a registered page. Browser subscriptions and thumbnail work stop when Home leaves.
@MainActor final class PluginCatalogSource {
    let descriptor: PluginCutCatalog
    let origin: PluginOrigin
    let page: Int
    var locationID: String { "plugin-cut:\(origin):\(descriptor.id)" }
    private var cards: [String: VirtualCutCard] = [:]
    private(set) var lastListing: BrowserListing?
    private var imageTask: Task<Void, Never>?
    private var wantedImages: [String] = []
    private var images: [String: CGImage] = [:]

    init(descriptor: PluginCutCatalog, origin: PluginOrigin, page: Int) {
        self.descriptor = descriptor
        self.origin = origin
        self.page = page
    }

    func listing() -> AsyncThrowingStream<BrowserListing, Error> {
        let endpoint = descriptor.endpoint
        return AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                do {
                    let list: [VirtualCutCard] = try await CatalogHTTP.decode(endpoint, limit: 1_048_576)
                    try Task.checkCancellation()
                    guard let self else { continuation.finish(); return }
                    guard list.count <= 2000, list.allSatisfy(\.isValid),
                          Set(list.map(\.id)).count == list.count else { throw CatalogHTTP.Failure.invalid }
                    let incoming = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
                    images = images.filter { incoming[$0.key]?.revision == cards[$0.key]?.revision }
                    cards = incoming
                    let listing = BrowserListing(entries: list.map {
                        BrowserEntry(url: endpoint.appendingPathComponent($0.id), name: $0.title, kind: .collection,
                                     key: $0.id, subtitle: FrameNaming.timecode($0.duration))
                    }, complete: true)
                    lastListing = listing
                    continuation.yield(listing)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func cut(_ id: String) async throws -> (VirtualCut, VirtualCutTimeline) {
        guard cards[id] != nil else { throw CatalogHTTP.Failure.invalid }
        return try await CatalogHTTP.cut(descriptor.endpoint.appendingPathComponent(id), id: id)
    }

    func want(_ ids: [String], publish: @escaping (String, CGImage) -> Void) {
        for id in ids { if let image = images[id] { publish(id, image) } }
        wantedImages = Array(ids.prefix(48)).filter { cards[$0] != nil && images[$0] == nil }
        guard imageTask == nil, !wantedImages.isEmpty else { return }
        imageTask = Task(priority: .utility) { [weak self] in
            while let self, !Task.isCancelled, !wantedImages.isEmpty {
                let id = wantedImages.removeFirst()
                guard let revision = cards[id]?.revision else { continue }
                let url = descriptor.endpoint.appendingPathComponent(id).appendingPathComponent("preview")
                if let image = try? await CatalogHTTP.image(url), !Task.isCancelled, cards[id]?.revision == revision {
                    if images.count >= 64 { images.removeAll(keepingCapacity: true) }
                    images[id] = image
                    publish(id, image)
                }
            }
            if !Task.isCancelled { self?.imageTask = nil }
        }
    }

    func stop() {
        imageTask?.cancel()
        imageTask = nil
        wantedImages = []
    }
}

private enum CatalogHTTP {
    enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: "The plugin returned an invalid catalog response."
            case .unavailable: "The plugin catalog could not be reached."
            }
        }
    }

    final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static let session = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    static func decode<T: Decodable & Sendable>(_ url: URL, limit: Int) async throws -> T {
        let data = try await data(url, limit: limit)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @concurrent static func cut(_ url: URL, id: String) async throws -> (VirtualCut, VirtualCutTimeline) {
        let cut: VirtualCut = try await decode(url, limit: 2_097_152)
        try Task.checkCancellation()
        guard cut.id == id, let timeline = cut.timeline else { throw Failure.invalid }
        return (cut, timeline)
    }

    static func image(_ url: URL) async throws -> CGImage? {
        let data = try await data(url, limit: 524_288)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func data(_ url: URL, limit: Int) async throws -> Data {
        let (stream, response) = try await session.bytes(for: URLRequest(url: url, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.unavailable }
        guard response.expectedContentLength <= Int64(limit) else { throw Failure.invalid }
        var bytes = Data()
        if response.expectedContentLength > 0 { bytes.reserveCapacity(Int(response.expectedContentLength)) }
        for try await byte in stream {
            guard bytes.count < limit else { throw Failure.invalid }
            bytes.append(byte)
        }
        return bytes
    }
}
