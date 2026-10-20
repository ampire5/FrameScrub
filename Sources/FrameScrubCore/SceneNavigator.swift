/// What a keyframe looks like to the scene jumps: a picture, or too dark to tell (a fade, a black frame).
public enum KeyframeLook: Equatable, Sendable {
    case picture(SceneSignature)
    case dark
}

/// Decides where the next or previous scene starts from the looks of the keyframes around the playhead.
/// The caller feeds it a chain of keyframes and decodes one more neighbour whenever it asks for one. Keyframes are a
/// coarse filter: a pair that differs enough is a candidate, which the caller checks frame by frame inside the GOP.
public struct SceneNavigator: Sendable {
    public enum Step: Equatable, Sendable {
        /// The chain is too short to decide: decode the keyframe next to this one, in this direction.
        case needNeighbour(of: Int, direction: Int)
        /// The keyframes `from` < `through` are a candidate: find the hard cuts among the frames between them.
        case needVerification(from: Int, through: Int)
        case found(Int)
        case none
    }

    /// A candidate without a hard cut inside its GOP still starts a scene (a dissolve, a flash) when its keyframes
    /// differ this much: the best threshold for keyframes alone, measured on real files (2026-10-14).
    public static let transitionThreshold = 70.0

    public static let defaultMinBackSeconds = 1.0

    public var threshold: Double
    /// Backwards, a scene start closer to the playhead than this does not count: the jump goes to the scene before.
    public var minBackSeconds: Double

    public init(threshold: Double, minBackSeconds: Double = defaultMinBackSeconds) {
        self.threshold = threshold
        self.minBackSeconds = minBackSeconds
    }

    /// `chain` runs in `direction` (+1 towards later frames, -1 towards earlier ones) from the keyframe at or before
    /// `position`; backwards it may start one keyframe after `position`, so cuts between the playhead and the keyframe
    /// before it are found. `atEdge`: there is no keyframe beyond its last element. `scenes` is how many scene starts to
    /// skip. `verified`: the hard cuts found inside the GOP of a candidate, keyed by its later keyframe (empty: none).
    /// Without `mayVerify` (no time left for GOP checks) a candidate not yet checked is judged by its keyframes: a scene
    /// starts at the later one when they differ by `transitionThreshold`.
    /// A dark keyframe is no scene of its own: a cut is judged between pictures, a candidate with dark keyframes between
    /// its pictures starts a scene at the later one without a check, and a picture after dark frames that open the
    /// chain starts a scene.
    public func step(position: Int, direction: Int, scenes: Int, chain: [(frame: Int, look: KeyframeLook)], atEdge: Bool,
                     verified: [Int: [Int]], mayVerify: Bool = true, seconds: (Int) -> Double) -> Step {
        guard let last = chain.last else { return .none }
        let wanted = max(scenes, 1)
        var starts = [Int]()
        if direction > 0 {
            var reference: (frame: Int, signature: SceneSignature)?
            var darkBetween = false
            for (index, item) in chain.enumerated() {
                guard case .picture(let signature) = item.look else {
                    darkBetween = reference != nil
                    continue
                }
                if let reference {
                    switch verdict(earlier: reference.frame, reference.signature, later: item.frame, signature,
                                   darkBetween: darkBetween, verified: verified, mayVerify: mayVerify) {
                    case .verify(let a, let b): return .needVerification(from: a, through: b)
                    case .starts(let frames): starts += frames.filter { $0 > position }
                    }
                } else if index > 0 {
                    // The chain's own first keyframe is the scene the playhead is in, not the start of another.
                    starts.append(item.frame)
                }
                reference = (item.frame, signature)
                darkBetween = false
                if starts.count >= wanted { return .found(starts[wanted - 1]) }
            }
        } else {
            var later: (frame: Int, signature: SceneSignature)?
            var darkBetween = false
            let now = seconds(position)
            for item in chain {
                guard case .picture(let signature) = item.look else {
                    darkBetween = later != nil
                    continue
                }
                if let later {
                    switch verdict(earlier: item.frame, signature, later: later.frame, later.signature,
                                   darkBetween: darkBetween, verified: verified, mayVerify: mayVerify) {
                    case .verify(let a, let b): return .needVerification(from: a, through: b)
                    case .starts(let frames):
                        for frame in frames.reversed() where frame <= position && now - seconds(frame) > minBackSeconds {
                            starts.append(frame)
                            if starts.count == wanted { return .found(frame) }
                        }
                    }
                }
                later = (item.frame, signature)
                darkBetween = false
            }
            // The file's first frame starts the scene of the earliest picture.
            if atEdge, later != nil, now - seconds(0) > minBackSeconds { starts.append(0) }
            if starts.count == wanted { return .found(0) }
        }
        if !atEdge { return .needNeighbour(of: last.frame, direction: direction) }
        return starts.last.map(Step.found) ?? .none
    }

    private enum Verdict {
        case verify(Int, Int)
        /// Scene starts in the pair's GOP, ascending (none: no cut).
        case starts([Int])
    }

    /// Whether the pictures `earlier` and `later` (keyframes) have a scene start between them, or need a check.
    private func verdict(earlier: Int, _ a: SceneSignature, later: Int, _ b: SceneSignature, darkBetween: Bool,
                         verified: [Int: [Int]], mayVerify: Bool) -> Verdict {
        let difference = a.difference(b)
        guard difference >= threshold else { return .starts([]) }
        if darkBetween { return .starts([later]) }
        guard let cuts = verified[later] else {
            return mayVerify ? .verify(earlier, later) : .starts(difference >= Self.transitionThreshold ? [later] : [])
        }
        if !cuts.isEmpty { return .starts(cuts.sorted()) }
        return .starts(difference >= Self.transitionThreshold ? [later] : [])
    }
}
