/// Skips export frames too like the last saved one (export dedupe spec §3): a frame is saved when at least
/// `minimumChange` of its picture differs from the last saved frame's, so a slow drift still saves a frame now and then.
public struct DuplicateFilter: Sendable {
    /// Of 255: a 64×36 cell that differs by no more than this in every colour has not changed. CALIBRATE
    public static let cellNoise = 16
    /// `export-duplicate-change`, percent. CALIBRATE
    public static let defaultChange = 5

    /// 0…1: share of the picture that has to change since the last saved frame.
    public let minimumChange: Double
    private var lastSaved: SceneSignature?

    public init(minimumChange: Double) {
        self.minimumChange = minimumChange
    }

    /// Percent of the picture that changed between two frames.
    public static func change(_ a: SceneSignature, _ b: SceneSignature) -> Double {
        a.changedShare(b, noise: cellNoise) * 100
    }

    /// Whether to save the frame with `signature`; it then becomes the frame the next ones are compared with.
    public mutating func keeps(_ signature: SceneSignature) -> Bool {
        if let lastSaved, lastSaved.changedShare(signature, noise: Self.cellNoise) < minimumChange { return false }
        lastSaved = signature
        return true
    }
}
