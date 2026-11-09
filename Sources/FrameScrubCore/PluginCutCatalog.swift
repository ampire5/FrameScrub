import Foundation

/// A configured page registers a catalog endpoint on its own HTTP origin.
public struct PluginCutCatalog: Equatable, Sendable {
    public let id: String
    public let title: String
    public let endpoint: URL

    public init?(id: String, title: String, endpoint: URL) {
        guard PluginActions.isValidName(id), !title.isEmpty, title.utf8.count <= 128,
              ["http", "https"].contains(endpoint.scheme?.lowercased() ?? ""),
              endpoint.host != nil, endpoint.user == nil, endpoint.password == nil,
              endpoint.query == nil, endpoint.fragment == nil else { return nil }
        self.id = id
        self.title = title
        self.endpoint = endpoint
    }

    public func allowed(from origin: PluginOrigin, configured: Set<PluginOrigin>) -> Bool {
        configured.contains(origin) && PluginOrigin(url: endpoint) == origin
    }
}

public struct VirtualCutCard: Codable, Equatable, Sendable {
    public let id: String
    public let revision: String
    public let title: String
    public let duration: Double

    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        } && !revision.isEmpty && revision.utf8.count <= 128 && !title.isEmpty && title.utf8.count <= 512
            && duration.isFinite && duration > 0
    }
}
