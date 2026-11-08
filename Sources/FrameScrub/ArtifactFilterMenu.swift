import AppKit
import FrameScrubCore
import FrameScrubSettings

/// Menu target retained by the root item; no second settings store or polling.
final class ArtifactFilterMenu: NSObject, NSMenuItemValidation {
    private let preferences: () -> PreferencesStore?
    private let onError: (String) -> Void
    private init(preferences: @escaping () -> PreferencesStore?, onError: @escaping (String) -> Void) {
        self.preferences = preferences; self.onError = onError
    }
    static func make(preferences: @escaping () -> PreferencesStore?, onError: @escaping (String) -> Void) -> NSMenuItem {
        let owner = ArtifactFilterMenu(preferences: preferences, onError: onError)
        let root = NSMenuItem(title: "Experimental Filters (SDR)", action: nil, keyEquivalent: "")
        root.representedObject = owner
        let menu = NSMenu(title: root.title)
        func add(_ title: String, _ action: Selector, _ tag: Int = 0, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = owner; item.tag = tag
            if !key.isEmpty { item.keyEquivalentModifierMask = [.command, .option] }
            menu.addItem(item)
        }
        add("Enable Filters / A–B", #selector(toggleEnabled), key: "b")
        add("Split: MetalFX Left / Filtered Right", #selector(toggleSplit))
        add("Show Changed Pixels (Red)", #selector(toggleChanges))
        menu.addItem(.separator())
        for (i,title) in ["Anti-ringing: Off", "Anti-ringing: Local Luma Limit", "Anti-ringing: Coherent Edges", "Edges: Directional Constrained Cleanup"].enumerated() { add(title, #selector(setAntiring(_:)), i) }
        menu.addItem(.separator())
        for (i,title) in ["Deband: Off", "Deband: Four Samples", "Deband: Two Passes", "Deband: Adaptive / Texture Protection", "Deband: libplacebo Logic", "Deband: Adaptive Window"].enumerated() { add(title, #selector(setDeband(_:)), i) }
        menu.addItem(.separator())
        for (i,title) in ["Chroma: Off", "Chroma: Bilateral 3×3", "Chroma: Bilateral 5×5", "Chroma: Median 3×3"].enumerated() { add(title, #selector(setChroma(_:)), i) }
        menu.addItem(.separator())
        for (i,title) in ["Grain: Off", "Grain: Uncorrelated / Comparison", "Grain: Fine", "Grain: Soft", "Grain: AV1-style", "Grain: Particles"].enumerated() { add(title, #selector(setGrain(_:)), i) }
        menu.addItem(.separator())
        for (i,title) in ["Preset: Smooth Gradients", "Preset: Combined Mild", "Preset: Adaptive Gradients", "Preset: Directional Cleanup", "Preset: Reference Deband", "Preset: Adaptive Window", "Preset: Fine Grain Only", "Preset: Cleanup + Fine Grain", "Reset All Experimental Filters", "Preset: Cleanup + AV1-style Grain", "Preset: Cleanup + Particle Grain"].enumerated() { add(title, #selector(preset(_:)), i) }
        root.submenu = menu; return root
    }
    private func update(_ keys: [String], _ edit: (inout ArtifactFilterSettings) -> Void) {
        guard let preferences = preferences() else { return }
        do { try preferences.update(keys) { edit(&$0.artifactFilters) } }
        catch { onError("Cannot save filter settings: \(error)") }
    }
    @objc private func toggleEnabled() { update(["artifact-enabled"]) { $0.enabled.toggle() } }
    @objc private func toggleSplit() { update(["artifact-compare"]) { $0.comparison = $0.comparison == .split ? .processed : .split } }
    @objc private func toggleChanges() { update(["artifact-compare"]) { $0.comparison = $0.comparison == .changes ? .processed : .changes } }
    @objc private func setAntiring(_ sender: NSMenuItem) { update(["artifact-antiring"]) { $0.antiring = ArtifactFilterSettings.Antiring.allCases[sender.tag] } }
    @objc private func setDeband(_ sender: NSMenuItem) { update(["artifact-deband"]) { $0.deband = ArtifactFilterSettings.Deband.allCases[sender.tag] } }
    @objc private func setGrain(_ sender: NSMenuItem) { update(["artifact-grain"]) { $0.grain = ArtifactFilterSettings.Grain.allCases[sender.tag] } }
    @objc private func setChroma(_ sender: NSMenuItem) { update(["artifact-chroma"]) { $0.chroma = ArtifactFilterSettings.Chroma.allCases[sender.tag] } }
    @objc private func preset(_ sender: NSMenuItem) {
        update(["artifact-grain", "artifact-grain-amount", "artifact-grain-size", "artifact-grain-base", "artifact-grain-adaptation", "artifact-enabled", "artifact-antiring", "artifact-deband", "artifact-chroma", "artifact-strength", "artifact-antiring-strength", "artifact-deband-strength", "artifact-deband-threshold", "artifact-deband-radius", "artifact-deband-iterations", "artifact-texture-protection", "artifact-chroma-strength", "artifact-dither", "artifact-compare"]) {
            $0 = ArtifactFilterSettings()
            switch sender.tag {
            case 0: $0.deband = .single
            case 1: $0.deband = .single; $0.debandStrength = 0.3
            case 2: $0.deband = .adaptive
            case 3: $0.antiring = .directional
            case 4: $0 = .referencePreset
            case 5: $0.deband = .window
            case 6: $0.grain = .fine; $0.grainAmount = 1; $0.grainSize = 1.25; $0.grainBase = 0.4
            case 7:
                $0.deband = .window
                $0.grain = .fine; $0.grainAmount = 1; $0.grainSize = 1.25; $0.grainBase = 0.4
            case 9: $0 = .texturedCleanup(grain: .av1)
            case 10: $0 = .texturedCleanup(grain: .particles)
            default: break
            }
        }
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let preferences = preferences() else { return false }
        let s = preferences.config.artifactFilters
        switch item.action {
        case #selector(toggleEnabled): item.state = s.enabled ? .on : .off
        case #selector(toggleSplit): item.state = s.comparison == .split ? .on : .off
        case #selector(toggleChanges): item.state = s.comparison == .changes ? .on : .off
        case #selector(setAntiring(_:)): item.state = s.antiring == ArtifactFilterSettings.Antiring.allCases[item.tag] ? .on : .off
        case #selector(setDeband(_:)): item.state = s.deband == ArtifactFilterSettings.Deband.allCases[item.tag] ? .on : .off
        case #selector(setGrain(_:)): item.state = s.grain == ArtifactFilterSettings.Grain.allCases[item.tag] ? .on : .off
        case #selector(setChroma(_:)): item.state = s.chroma == ArtifactFilterSettings.Chroma.allCases[item.tag] ? .on : .off
        default: break
        }
        return true
    }
}
