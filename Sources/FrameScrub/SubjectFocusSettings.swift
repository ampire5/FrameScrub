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

    /// A look the user saved under a name: a button after the standard ones, shown as the custom style.
    struct Preset: Codable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var look: SubjectFocusStyle.Look
    }
    /// One of the buttons: a standard style (Custom included) or the user's preset.
    enum Choice: Equatable {
        case style(SubjectFocusStyle)
        case preset(UUID)
    }
    /// The user's presets, in the order they were saved.
    var presets: [Preset] {
        didSet {
            if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: Self.prefix + "presets") }
            if let id = activePreset, !presets.contains(where: { $0.id == id }) { activePreset = nil }
            post(masks: false)
        }
    }
    /// The preset the custom style shows; nil: the custom look itself.
    var activePreset: UUID? {
        didSet { defaults.set(activePreset?.uuidString, forKey: Self.prefix + "activePreset"); post(masks: false) }
    }
    /// The standard styles' buttons hidden (Custom and the user's presets stay); ⇧H steps through what is shown.
    var hideStandard: Bool { didSet { defaults.set(hideStandard, forKey: Self.prefix + "hideStandard"); post(masks: false) } }
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
        presets = d.data(forKey: Self.prefix + "presets").flatMap { try? JSONDecoder().decode([Preset].self, from: $0) } ?? []
        activePreset = d.string(forKey: Self.prefix + "activePreset").flatMap(UUID.init(uuidString:))
        hideStandard = bool("hideStandard", false)
        cleanEdge = env["FRAMESCRUB_FOCUS_CLEAN_EDGE"].map { $0 != "0" } ?? bool("cleanEdge", true)
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

    /// The look `style` draws with: the custom style shows the active preset, else the custom look.
    func look(_ style: SubjectFocusStyle) -> SubjectFocusStyle.Look {
        guard style == .custom else { return style.preset }
        return activePreset.flatMap { id in presets.first { $0.id == id }?.look } ?? custom
    }

    /// The buttons in order: the standard styles (unless hidden), Custom, then the user's presets.
    var choices: [Choice] {
        let standard = SubjectFocusStyle.allCases.filter { $0 != .custom && !hideStandard }.map(Choice.style)
        return standard + [.style(.custom)] + presets.map { .preset($0.id) }
    }

    /// The button `style` on screen stands for.
    func choice(for style: SubjectFocusStyle) -> Choice {
        if style == .custom, let id = activePreset { return .preset(id) }
        return .style(style)
    }

    /// Makes `choice` the one drawn and returns the style to turn on (a preset is the custom style showing it).
    func select(_ choice: Choice) -> SubjectFocusStyle {
        switch choice {
        case let .style(style):
            if style == .custom { activePreset = nil }
            return style
        case let .preset(id):
            activePreset = id
            return .custom
        }
    }

    /// ⇧H: the button after the one for `style` (the first one when it is hidden).
    func next(after style: SubjectFocusStyle) -> Choice {
        let all = choices, current = choice(for: style)
        guard let i = all.firstIndex(of: current) else { return all[0] }
        return all[(i + 1) % all.count]
    }

    /// The name the OSD and the buttons show.
    func title(of choice: Choice) -> String {
        switch choice {
        case let .style(style): style.title
        case let .preset(id): presets.first { $0.id == id }?.name ?? "Custom"
        }
    }

    /// Saves `look` as a new preset named `name` and makes it the active one.
    @discardableResult func addPreset(named name: String, look: SubjectFocusStyle.Look) -> UUID {
        let preset = Preset(name: name, look: look)
        presets.append(preset)
        activePreset = preset.id
        return preset.id
    }

    /// The next free "Preset N".
    var newPresetName: String {
        var n = presets.count + 1
        while presets.contains(where: { $0.name == "Preset \(n)" }) { n += 1 }
        return "Preset \(n)"
    }

    /// Everything back as it came (the custom look as Studio).
    func reset() {
        custom = SubjectFocusStyle.studio.preset
        activePreset = nil   // the user's presets stay
        hideStandard = false
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
