import Testing
@testable import FrameScrubCore

@Suite struct KeyHelpTests {
    @Test func keyNamesUseMacGlyphs() {
        #expect(KeyChord(key: "LEFT", modifiers: .shift).displayName == "⇧←")
        #expect(KeyChord(key: "s").displayName == "s")
        #expect(KeyChord(key: "S").displayName == "⇧S")
        #expect(KeyChord.parse("Meta+O")!.displayName == "⇧⌘O")
        #expect(KeyChord.parse("Meta+g")!.displayName == "⌘g")
        #expect(KeyChord.parse("Ctrl+Alt+RIGHT")!.displayName == "⌃⌥→")
        #expect(KeyChord(key: "?").displayName == "?")
        #expect(KeyChord(key: "BS", modifiers: .shift).displayName == "⇧⌫")
        #expect(KeyChord(key: "MBTN_RIGHT").displayName == "Right click")
        #expect(KeyChord(key: "MBTN_RIGHT").isPointer && !KeyChord(key: "SPACE").isPointer)
        #expect(KeyChord.parse("MBTN_RIGHT+WHEEL_LEFT")!.displayName == "Right button + Side wheel left")
        #expect(KeyChord.parse("MBTN_RIGHT+Shift+MBTN_MID")!.displayName == "Right button + ⇧Middle click")
        #expect(KeyChord.parse("MBTN_MID+WHEEL_UP")!.displayName == "Middle + Wheel ↑")
        #expect(KeyChord(key: "MBTN_BACK").displayName == "Back button")
        #expect(KeyChord(key: "MBTN_FORWARD_DBL").displayName == "Forward button double click")
    }

    @Test func namesTheLogitechButtonsAndHeldPrefixes() {
        #expect(KeyChord.parse("MX_PANEL+WHEEL_UP")!.displayName == "Panel + Wheel ↑")
        #expect(KeyChord.parse("MX_GESTURE+WHEEL_DOWN")!.displayName == "Gesture button + Wheel ↓")
        #expect(KeyChord.parse("MBTN_BACK+WHEEL_UP")!.displayName == "Back + Wheel ↑")
        #expect(KeyChord.parse("MBTN_FORWARD+Alt+WHEEL_UP")!.displayName == "Forward + ⌥Wheel ↑")
        #expect(KeyChord.parse("MBTN_RIGHT+MBTN_BACK+WHEEL_UP")!.displayName == "Right button + Back + Wheel ↑")
        #expect(KeyChord(key: "MX_PANEL").displayName == "Panel")
        #expect(KeyChord(key: "MX_PANEL_LONG").displayName == "Panel (hold)")
        #expect(KeyChord(key: "MX_GESTURE").displayName == "Gesture button")
        #expect(KeyChord(key: "MX_GESTURE_LONG").displayName == "Gesture button (hold)")
        #expect(KeyChord(key: "MX_SHIFT").displayName == "Shift button")
        #expect(KeyChord(key: "MBTN_BACK_LONG").displayName == "Back (hold)")
        #expect(KeyChord(key: "MBTN_FORWARD_LONG").displayName == "Forward (hold)")
        #expect(KeyChord(key: "WHEEL_LEFT").displayName == "Side wheel left")
        #expect(KeyChord(key: "WHEEL_RIGHT").displayName == "Side wheel right")
        #expect(KeyChord(key: "MX_PANEL").isPointer && KeyChord(key: "MX_SHIFT_LONG").isPointer)
    }

    @Test func mouseDefaultsAreInTheCheatSheetAndOutOfMenuHints() {
        for layout in [KeyLayout.classic, .leftHand] {
            let map = InputMap(layout: layout)
            let all = KeyHelp.sections(for: map).flatMap(\.entries)
            #expect(all.contains { $0.action == "Drag the mark start" && $0.keys.contains("Back + Wheel ↑↓") }, "\(layout)")
            #expect(all.contains { $0.action == "Drag the mark end" && $0.keys.contains("Forward + Wheel ↑↓") }, "\(layout)")
            #expect(all.contains { $0.action == "Auto colour strength +0.05" && $0.keys == ["Panel + Wheel ↑"] }, "\(layout)")
            #expect(all.contains { $0.action == "Auto colour strength −0.05" && $0.keys == ["Panel + Wheel ↓"] }, "\(layout)")
            #expect(Set(all.map(\.action)).count == all.count)
            #expect(KeyHelp.menuHint(for: .markIn, in: map).map { !$0.contains("Back") } ?? true)
            #expect(KeyHelp.menuHint(for: .toggleAutoColor, in: map).map { !$0.contains("Panel") } ?? true)
        }
    }

    @Test func groupsTheDefaultsBySectionWithAllTheirKeys() {
        let sections = KeyHelp.sections(for: InputMap(layout: .classic))
        #expect(sections.map(\.section) == KeyHelp.Section.allCases.filter { $0 != .plugin })   // no page actions declared
        let playback = sections[0].entries
        #expect(playback.first == KeyHelp.Entry(keys: ["Space", "p", "Right click"], action: "Play / pause"))
        let all = sections.flatMap(\.entries)
        #expect(all.contains(KeyHelp.Entry(keys: ["?"], action: "These keys")))
        #expect(all.contains { $0.action == "Step frames" && $0.keys == ["Swipe ←→", "Wheel ↑↓", "⇧Side wheel left"] })
        #expect(!all.contains { $0.action.lowercased().contains("zoom") })   // bound, but there is no zoom yet
        #expect(Set(all.map(\.action)).count == all.count)
    }

    @Test func colourMemoryCommandsHaveCheatSheetLabels() {
        let labels: [(Command, String)] = [
            (.toggleAutoColor, "Auto colour on/off (this file)"), (.toggleVibrance, "Vibrance on/off (this file)"),
            (.saveAutoColor(folder: false), "Save auto colour as default"),
            (.saveAutoColor(folder: true), "Save auto colour for the folder"),
            (.saveVibrance(folder: false), "Save vibrance as default"),
            (.saveVibrance(folder: true), "Save vibrance for the folder"),
            (.resetColor(.file), "Reset file colour"), (.resetColor(.folder), "Reset folder colour"),
        ]
        for (command, label) in labels {
            let described = KeyHelp.describe(command)
            #expect(described?.section == .picture && described?.action == label, "\(command.configText)")
        }
        let picture = KeyHelp.sections(for: InputMap(layout: .classic)).first { $0.section == .picture }!.entries
        #expect(picture.first { $0.action == "Save auto colour as default" }?.keys == ["⇧C"])
        #expect(picture.first { $0.action == "Save vibrance for the folder" }?.keys == ["⌥v"])
        #expect(picture.first { $0.action == "Auto colour on/off (this file)" }?.keys.first == "c")
        let saving = KeyHelp.sections(for: InputMap(layout: .classic)).first { $0.section == .saving }!.entries
        #expect(saving.first { $0.action == "Save the marks as clips" }?.keys.first == "⇧⌘C")
    }

    @Test func listsTheSceneJumpsUnderSeeking() {
        let seeking = KeyHelp.sections(for: InputMap()).first { $0.section == .navigation }!.entries
        #expect(seeking.contains(KeyHelp.Entry(keys: ["⇧↑"], action: "Next scene")))
        #expect(seeking.contains(KeyHelp.Entry(keys: ["⇧↓"], action: "Previous scene (or start of this one)")))
        let actions = seeking.map(\.action)
        #expect(actions.firstIndex(of: "Previous scene (or start of this one)")! < actions.firstIndex(of: "Next scene")!)
        #expect(actions.firstIndex(of: "Next scene")! < actions.firstIndex(of: "Previous video in the folder")!)
    }

    @Test func followsInputConf() {
        var map = InputMap(layout: .classic)
        map.apply("s ignore\nCtrl+e screenshot")
        let saving = KeyHelp.sections(for: map).first { $0.section == .saving }!.entries
        #expect(saving.first == KeyHelp.Entry(keys: ["⌃e", "Gesture button"], action: "Save frame"))
    }

    @Test func condensesArrowPairs() {
        #expect(KeyHelp.condensed(["Swipe ←", "Swipe →", "a", "b", "c"]) == ["Swipe ←→", "a", "b"])
        #expect(KeyHelp.condensed(["←", "→"]) == ["←→"])
        #expect(KeyHelp.condensed(["Wheel ↓", "Wheel ↑"]) == ["Wheel ↑↓"])
        #expect(KeyHelp.condensed(["Wheel ↑", "Swipe ↓"]) == ["Wheel ↑", "Swipe ↓"])
    }

    @Test func menuHintPrefersAPlainKey() {
        let map = InputMap(layout: .classic)
        #expect(KeyHelp.menuHint(for: .cyclePause, in: map) == "Space")
        #expect(KeyHelp.menuHint(for: .keyframeStep, in: map) == "⌥→")
        #expect(KeyHelp.menuHint(for: .playlistNext, in: map) == "PgDn")
        #expect(KeyHelp.menuHint(for: .zoomReset, in: map) == "⌘0")
        #expect(KeyHelp.menuHint(for: .quit, in: InputMap(layout: .classic)) == "q")
        var none = InputMap(layout: .classic)
        none.apply("q ignore")
        #expect(KeyHelp.menuHint(for: .quit, in: none) == nil)
    }

    @Test func normalSpeedIsFoundUnderItsKeys() {
        let classic = InputMap(layout: .classic)
        #expect(KeyHelp.menuHint(for: .setSpeed(1), in: classic) == "⌫")
        let all = KeyHelp.sections(for: classic).flatMap(\.entries)
        #expect(all.contains { $0.action == "Normal speed (1×)" && $0.keys.contains("⌫") })
        let leftHand = KeyHelp.sections(for: InputMap(layout: .leftHand)).flatMap(\.entries)
        #expect(leftHand.contains { $0.action == "Normal speed (1×)" })
    }

    @Test func leftHandHintsShowTheLeftHandKey() {
        let map = InputMap(layout: .leftHand)
        #expect(KeyHelp.menuHint(for: .seek(5, .byConfig), in: map) == "c")
        #expect(KeyHelp.menuHint(for: .frameStep, in: map) == "e")
        #expect(KeyHelp.menuHint(for: .keyframeStep, in: map) == "⇧E")
        #expect(KeyHelp.menuHint(for: .togglePlaylist, in: map) == "⇥")
        #expect(KeyHelp.menuHint(for: .saveClip, in: map) == "b")
        #expect(KeyHelp.menuHint(for: .quit, in: map) == nil)
    }

    @Test func leftHandCheatSheetListsPrimaryKeysFirst() {
        let entries = KeyHelp.sections(for: InputMap(layout: .leftHand)).flatMap(\.entries)
        #expect(entries.first { $0.action == "Seek +5 s" }?.keys.first == "c")
        #expect(entries.first { $0.action == "Next frame" }?.keys.first == "e")
        #expect(entries.first { $0.action == "Save the marks as clips" }?.keys == ["b", "Gesture button (hold)"])
        #expect(!entries.contains { ($0.action.hasPrefix("A-B range") && $0.keys.contains("l")) || $0.keys.contains("⇧S") })
    }

    @Test func segmentLockIsRightAfterABInThePlaybackSection() {
        let playback = KeyHelp.sections(for: InputMap()).first { $0.section == .playback }!.entries.map(\.action)
        let a = playback.firstIndex { $0.hasPrefix("A-B range") }!
        #expect(playback.firstIndex(of: "At B: loop, pause or turn back") == a + 1)
        #expect(playback.firstIndex(of: "Segments: lock / unlock") == a + 2)
    }

    @Test func shuttleIsInThePlaybackSection() {
        let map = InputMap(layout: .leftHand)
        #expect(KeyHelp.menuHint(for: .shuttleBack, in: map) == "a")
        let playback = KeyHelp.sections(for: map).first { $0.section == .playback }!.entries.map(\.action)
        #expect(playback.contains("Shuttle back") && playback.contains("Stop") && playback.contains("Shuttle forward"))
    }

    @Test func pluginSectionListsTheDeclaredActionsLast() {
        var base = InputMap(layout: .classic)
        base.apply("Alt+9 plugin-action next")
        let actions = [PluginAction(name: "mark", label: "Mark here", key: KeyChord.parse("Alt+1")),
                       PluginAction(name: "next", label: "Next item", key: KeyChord.parse("Alt+2")),
                       PluginAction(name: "skip", label: "Skip", key: nil)]
        let map = base.merging(actions).map
        let sections = KeyHelp.sections(for: map, plugin: actions)
        #expect(sections.last?.section == .plugin)
        #expect(KeyHelp.Section.plugin.title == "Plugin")
        #expect(sections.last?.entries == [KeyHelp.Entry(keys: ["⌥1"], action: "Mark here"),
                                           KeyHelp.Entry(keys: ["⌥9"], action: "Next item"),
                                           KeyHelp.Entry(keys: [], action: "Skip")])
        #expect(!sections.dropLast().flatMap(\.entries).contains { $0.action.contains("plugin") })
    }

    @Test func noPluginSectionWithoutActions() {
        var map = InputMap()
        map.apply("Alt+9 plugin-action mark")
        #expect(!KeyHelp.sections(for: map).contains { $0.section == .plugin })
        #expect(!KeyHelp.sections(for: map, plugin: []).contains { $0.section == .plugin })
    }
}
