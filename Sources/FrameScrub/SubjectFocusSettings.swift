import Foundation

/// Subject Focus's settings beyond the style (spike): the custom look, the edge's colour, the mask (RVM or Vision, its
/// quality and steadiness, the sharper still frame), who is the subject and the mask overlay. One set for every window,
/// kept in `UserDefaults` (the spike stays out of framescrub.conf, so other builds never meet its keys there); a change
/// posts `changed`, and the windows redraw, or make their masks again when the mask's settings changed.
@MainActor final class SubjectFocusSettings {
    static let shared = SubjectFocusSettings()
    /// `userInfo["masks"]`: true when the masks must be made again (not only redrawn).
    static let changed = Notification.Name("FrameScrubSubjectFocusSettingsChanged")

    enum VisionQuality: String, CaseIterable, Sendable { case fast, balanced, accurate }

    /// The smoothing the masks were measured with (`SubjectMasker`'s keep values at this setting).
    nonisolated static let defaultSteadiness = 0.6

    private let defaults = UserDefaults.standard
    private static let prefix = "SubjectFocus."

    /// The custom style's look.
    var custom: SubjectFocusStyle.Look { didSet { save(custom, "custom"); post(masks: false) } }
    /// The edge band takes the person's own colours (no rim of the old background).
    var cleanEdge: Bool { didSet { defaults.set(cleanEdge, forKey: Self.prefix + "cleanEdge"); post(masks: false) } }
    /// RVM's matte (when the user prepared its models) instead of Vision's masks.
    var matting: Bool { didSet { defaults.set(matting, forKey: Self.prefix + "matting"); post(masks: true) } }
    /// Vision's quality while playing (a still frame gets accurate).
    var visionQuality: VisionQuality {
        didSet { defaults.set(visionQuality.rawValue, forKey: Self.prefix + "visionQuality"); post(masks: true) }
    }
    /// 0…1: how much Vision's playback masks are smoothed over time (RVM holds still by itself).
    var steadiness: Double { didSet { defaults.set(steadiness, forKey: Self.prefix + "steadiness"); post(masks: true) } }
    /// A frame on screen for a moment (paused) gets its own finer mask.
    var stillAccurate: Bool { didSet { defaults.set(stillAccurate, forKey: Self.prefix + "stillAccurate"); post(masks: true) } }
    /// Only the main people (`SubjectSelection`), not everyone.
    var mainPeople: Bool { didSet { defaults.set(mainPeople, forKey: Self.prefix + "mainPeople"); post(masks: true) } }
    /// The mask tinted over the people.
    var showMask: Bool { didSet { post(masks: false) } }

    private init() {
        let env = ProcessInfo.processInfo.environment
        let d = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: Self.prefix + key) as? Bool ?? fallback }
        custom = (d.data(forKey: Self.prefix + "custom")).flatMap { try? JSONDecoder().decode(SubjectFocusStyle.Look.self, from: $0) }
            ?? SubjectFocusStyle.studio.preset
        cleanEdge = bool("cleanEdge", true)
        // Benches: `FRAMESCRUB_FOCUS_QUALITY=fast|balanced|accurate` starts with Vision at that quality,
        // `FRAMESCRUB_FOCUS_MAIN=1` with the main people only.
        let quality = env["FRAMESCRUB_FOCUS_QUALITY"].flatMap(VisionQuality.init(rawValue:))
        matting = SubjectMatting.isAvailable && quality == nil && bool("matting", true)
        visionQuality = quality ?? d.string(forKey: Self.prefix + "visionQuality").flatMap(VisionQuality.init(rawValue:)) ?? .balanced
        steadiness = d.object(forKey: Self.prefix + "steadiness") as? Double ?? Self.defaultSteadiness
        stillAccurate = bool("stillAccurate", true)
        mainPeople = env["FRAMESCRUB_FOCUS_MAIN"] == "1" || bool("mainPeople", false)
        showMask = false
    }

    /// The look `style` draws with.
    func look(_ style: SubjectFocusStyle) -> SubjectFocusStyle.Look { style == .custom ? custom : style.preset }

    /// Everything back as it came (the custom look as Studio).
    func reset() {
        custom = SubjectFocusStyle.studio.preset
        cleanEdge = true
        matting = SubjectMatting.isAvailable
        visionQuality = .balanced
        steadiness = Self.defaultSteadiness
        stillAccurate = true
        mainPeople = false
        showMask = false
    }

    private func save(_ look: SubjectFocusStyle.Look, _ key: String) {
        if let data = try? JSONEncoder().encode(look) { defaults.set(data, forKey: Self.prefix + key) }
    }

    private func post(masks: Bool) {
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: ["masks": masks])
    }
}
