public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg, png, heic, tiff

    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}
