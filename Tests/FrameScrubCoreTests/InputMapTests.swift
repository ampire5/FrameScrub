import Testing
@testable import FrameScrubCore

@Suite struct InputMapTests {
    @Test func slotChordsAreMenuOwned() throws {
        for key in ["LEFT", "RIGHT", "DOWN"] {
            #expect(KeyChord.menuOwned.contains(try #require(KeyChord.parse("Ctrl+Meta+\(key)"))))
        }
    }

    @Test func theHeldRightButtonIsAModifier() {
        let chord = KeyChord.parse("MBTN_RIGHT+WHEEL_LEFT")
        #expect(chord == KeyChord(key: "WHEEL_LEFT", modifiers: .rightButton))
        #expect(chord?.description == "MBTN_RIGHT+WHEEL_LEFT")
        #expect(KeyChord.parse("MBTN_RIGHT") == KeyChord(key: "MBTN_RIGHT"))    // the button itself, not a modifier
        #expect(KeyChord.parse("Shift+MBTN_RIGHT+MBTN_MID") == KeyChord(key: "MBTN_MID", modifiers: [.shift, .rightButton]))
        #expect(KeyChord.parse("MBTN_RIGHT+MBTN_MID")?.description == "MBTN_RIGHT+MBTN_MID")
    }

    @Test func toggleSegmentLockIsOnAltLAndAltShiftF() {
        #expect(InputMap(layout: .classic).command(for: KeyChord.parse("Alt+l")!) == .toggleSegmentLock)
        #expect(InputMap(layout: .leftHand).command(for: KeyChord.parse("Alt+F")!) == .toggleSegmentLock)
        #expect(Command.toggleSegmentLock.configText == "toggle-segment-lock")
        var map = InputMap()
        #expect(map.apply("x toggle-segment-lock").isEmpty)
        #expect(map.command(for: KeyChord.parse("x")!) == .toggleSegmentLock)
    }

    @Test func altMTogglesScrubAudioInBothLayouts() {
        for layout in [KeyLayout.classic, .leftHand] {
            #expect(InputMap(layout: layout).command(for: KeyChord.parse("Alt+m")!) == .toggleScrubAudio, "\(layout)")
        }
        #expect(Command.toggleScrubAudio.configText == "toggle-scrub-audio")
        var map = InputMap()
        #expect(map.apply("x toggle-scrub-audio").isEmpty)
        #expect(map.command(for: KeyChord(key: "x")) == .toggleScrubAudio)
    }

    @Test func closeFileParsesAndRoundTrips() {
        #expect(Command.parse("close-file") == .closeFile)
        #expect(Command.closeFile.configText == "close-file")
        #expect(!Command.closeFile.repeatsWhenHeld)
    }

    @Test func closeFileOnCommandWInBothLayouts() {
        for layout in [KeyLayout.classic, .leftHand] {
            #expect(InputMap(layout: layout).command(for: KeyChord.parse("Meta+w")!) == .closeFile, "\(layout)")
        }
    }

    @Test func shiftAltMTogglesScrubPitchInBothLayouts() {
        for layout in [KeyLayout.classic, .leftHand] {
            #expect(InputMap(layout: layout).command(for: KeyChord.parse("Alt+M")!) == .toggleScrubAudioPitch, "\(layout)")
        }
        #expect(Command.toggleScrubAudioPitch.configText == "toggle-scrub-audio-pitch")
        var map = InputMap()
        #expect(map.apply("x toggle-scrub-audio-pitch").isEmpty)
        #expect(map.command(for: KeyChord(key: "x")) == .toggleScrubAudioPitch)
    }

    @Test func mouseButtonLinesBindWithoutWarnings() {
        var map = InputMap()
        let warnings = map.apply("""
        MBTN_RIGHT+WHEEL_LEFT   step-speed down
        MBTN_MID                cycle fullscreen     # middle
        MBTN_FORWARD            screenshot
        MBTN_FORWARD_DBL        ab-loop
        MBTN_RIGHT+MBTN_MID     set speed 1.0
        MBTN_RIGHT+MBTN_FORWARD export-range
        """)
        #expect(warnings.isEmpty)
        #expect(map.command(for: KeyChord(key: "WHEEL_LEFT", modifiers: .rightButton)) == .stepSpeed(-1))
        #expect(map.command(for: KeyChord(key: "MBTN_FORWARD_DBL")) == .abLoop)
        #expect(map.command(for: KeyChord(key: "MBTN_MID", modifiers: .rightButton)) == .setSpeed(1))
        #expect(map.command(for: KeyChord(key: "MBTN_FORWARD", modifiers: .rightButton)) == .exportRange)
    }

    @Test func rightButtonScrollScrubsFastByDefaultInBothLayouts() {
        for layout in [KeyLayout.classic, .leftHand] {
            let map = InputMap(layout: layout)
            for key in ["WHEEL_UP", "WHEEL_DOWN",
                        "TRACKPAD_UP", "TRACKPAD_DOWN", "TRACKPAD_LEFT", "TRACKPAD_RIGHT"] {
                #expect(map.command(for: KeyChord(key: key, modifiers: .rightButton)) == .scrub(fast: true, invert: false),
                        "\(layout) \(key)")
            }
        }
    }

    @Test func defaultBindingsMatchSpec() {
        let map = InputMap(layout: .classic)
        #expect(map.command(for: KeyChord(key: "SPACE")) == .cyclePause)
        #expect(map.command(for: KeyChord(key: "p")) == .cyclePause)
        #expect(map.command(for: KeyChord(key: "MBTN_RIGHT")) == .cyclePause)
        #expect(map.command(for: KeyChord(key: "LEFT")) == .seek(-5, .byConfig))
        #expect(map.command(for: KeyChord(key: "UP")) == .seek(60, .byConfig))
        #expect(map.command(for: KeyChord(key: "RIGHT", modifiers: .shift)) == .seek(1, .exact))
        #expect(map.command(for: KeyChord(key: ",")) == .frameBackStep)
        #expect(map.command(for: KeyChord(key: ".")) == .frameStep)
        #expect(map.command(for: KeyChord(key: "[")) == .stepSpeed(-1))
        #expect(map.command(for: KeyChord(key: "]")) == .stepSpeed(1))
        #expect(map.command(for: KeyChord(key: "BS")) == .setSpeed(1))
        #expect(map.command(for: KeyChord(key: "0")) == .addVolume(2))
        #expect(map.command(for: KeyChord(key: "m")) == .cycleMute)
        #expect(map.command(for: KeyChord(key: "MBTN_LEFT_DBL")) == .cycleFullscreen)
        #expect(map.command(for: KeyChord(key: "MBTN_MID")) == .cycleFullscreen)
        #expect(map.command(for: KeyChord.parse("MBTN_MID+WHEEL_UP")!) == .addVolume(5))
        #expect(map.command(for: KeyChord.parse("MBTN_MID+WHEEL_DOWN")!) == .addVolume(-5))
        #expect(map.command(for: KeyChord(key: "ESC")) == .setFullscreen(false))
        #expect(map.command(for: KeyChord(key: "i")) == .stats)
        #expect(map.command(for: KeyChord(key: "PGUP")) == .playlistPrev)
        #expect(map.command(for: KeyChord(key: "PGDWN")) == .playlistNext)
        #expect(map.command(for: KeyChord(key: "g", modifiers: .meta)) == .goTo)
        #expect(map.command(for: KeyChord(key: "/")) == .holdSpeed)
        #expect(map.command(for: KeyChord(key: "l")) == .abLoop)
        #expect(map.command(for: KeyChord(key: "L")) == .cycleABLoopMode)
        #expect(map.command(for: KeyChord(key: "I")) == .markIn)
        #expect(map.command(for: KeyChord(key: "O")) == .markOut)
        #expect(map.command(for: KeyChord(key: "{")) == .markPrev)
        #expect(map.command(for: KeyChord(key: "}")) == .markNext)
        #expect(map.command(for: KeyChord(key: "k")) == .markSnap)
        #expect(map.command(for: KeyChord(key: "M")) == .markLoop)
        #expect(map.command(for: KeyChord(key: "x")) == .markDelete)
        #expect(map.command(for: KeyChord(key: "X")) == .markClear)
        #expect(map.command(for: KeyChord(key: "P")) == .playMarks)
        #expect(map.command(for: KeyChord(key: "s")) == .screenshot)
        #expect(map.command(for: KeyChord(key: "S")) == .exportRange)
        #expect(map.command(for: KeyChord.parse("Meta+C")!) == .saveClip)
        #expect(map.command(for: KeyChord(key: "q")) == .quit)
        // Gestures (spec §10)
        #expect(map.command(for: KeyChord(key: "TRACKPAD_LEFT")) == .scrub(fast: false, invert: false))
        #expect(map.command(for: KeyChord(key: "TRACKPAD_RIGHT", modifiers: .shift)) == .scrub(fast: true, invert: false))
        #expect(map.command(for: KeyChord(key: "TRACKPAD_UP")) == .addVolume(2))
        #expect(map.command(for: KeyChord(key: "TRACKPAD_DOWN", modifiers: .meta)) == .zoom(-0.25))
        #expect(map.command(for: KeyChord(key: "PINCH_OUT")) == .zoom(nil))
        #expect(map.command(for: KeyChord(key: "WHEEL_DOWN")) == .scrub(fast: false, invert: false))
        #expect(map.command(for: KeyChord(key: "WHEEL_DOWN", modifiers: .alt)) == .addVolume(-2))
        #expect(map.command(for: KeyChord(key: "WHEEL_LEFT", modifiers: .shift)) == .scrub(fast: false, invert: false))
        #expect(map.command(for: KeyChord(key: "WHEEL_RIGHT", modifiers: [.shift, .alt])) == .scrub(fast: true, invert: false))
        #expect(map.command(for: KeyChord(key: "WHEEL_UP", modifiers: .meta)) == .zoom(0.25))
        // New commands (spec §12)
        #expect(map.command(for: KeyChord(key: "<")) == .playlistPrev)
        #expect(map.command(for: KeyChord(key: ">")) == .playlistNext)
        #expect(map.command(for: KeyChord(key: "F8")) == .togglePlaylist)
        #expect(map.command(for: KeyChord(key: "u")) == .toggleUpscaler)
        #expect(map.command(for: KeyChord(key: "U")) == .cycleUpscaler)
        #expect(map.command(for: KeyChord(key: "2", modifiers: .meta)) == .windowScale(1))
        #expect(map.command(for: KeyChord(key: "4", modifiers: .meta)) == .windowFit)
        #expect(map.command(for: KeyChord(key: "c", modifiers: .meta)) == .copyFrame)
        #expect(map.command(for: KeyChord(key: "O", modifiers: .meta)) == .revealFrames)
        #expect(map.command(for: KeyChord(key: "=", modifiers: .meta)) == .zoom(0.25))
        #expect(map.command(for: KeyChord(key: "0", modifiers: .meta)) == .zoomReset)
        // Backlog item 4
        #expect(map.command(for: KeyChord(key: "LEFT", modifiers: .ctrl)) == .keyframeBackStep)
        #expect(map.command(for: KeyChord(key: "RIGHT", modifiers: .ctrl)) == .keyframeStep)
        #expect(map.command(for: KeyChord(key: "LEFT", modifiers: .alt)) == .keyframeBackStep)
        #expect(map.command(for: KeyChord(key: "RIGHT", modifiers: .alt)) == .keyframeStep)
        #expect(map.command(for: KeyChord(key: "BS", modifiers: .shift)) == .revertSeek)
        #expect(map.command(for: KeyChord(key: "T")) == .cycleOntop)
    }

    @Test func colorCorrectionKeys() {
        let map = InputMap(layout: .classic)
        #expect(map.command(for: KeyChord(key: "v")) == .toggleVibrance)
        #expect(map.command(for: KeyChord(key: "c")) == .toggleAutoColor)
        #expect(map.command(for: KeyChord(key: "V")) == .saveVibrance(folder: false))
        #expect(Command.parse("toggle-vibrance") == .toggleVibrance)
        #expect(Command.parse("toggle-auto-color") == .toggleAutoColor)
        #expect(Command.parse(Command.toggleAutoColor.configText) == .toggleAutoColor)
        #expect(!Command.toggleVibrance.repeatsWhenHeld && !Command.toggleAutoColor.repeatsWhenHeld)
    }

    @Test func aCyclesTheAspect() {
        #expect(InputMap(layout: .classic).command(for: KeyChord(key: "a")) == .cycleAspect)
        #expect(Command.parse(Command.cycleAspect.configText) == .cycleAspect)
        #expect(!Command.cycleAspect.repeatsWhenHeld)
    }

    @Test func bindsThePlaylistCommands() {
        let map = InputMap(layout: .classic)
        #expect(map.command(for: KeyChord(key: "BS", modifiers: .meta)) == .deleteFile)
        #expect(map.command(for: KeyChord(key: "F9")) == .cyclePlaylistSort)
        #expect(map.command(for: KeyChord(key: "f", modifiers: .meta)) == .playlistFilter)
        for command: Command in [.deleteFile, .cyclePlaylistSort, .playlistFilter] {
            #expect(Command.parse(command.configText) == command)
            #expect(!command.repeatsWhenHeld)
        }
        #expect(Command.parse("delete-file") == .deleteFile)
    }

    @Test func saveClipRoundTrips() {
        #expect(Command.parse("save-clip") == .saveClip)
        #expect(Command.parse(Command.saveClip.configText) == .saveClip)
    }

    @Test func colourMemoryCommandsRoundTrip() {
        let commands: [(Command, String)] = [
            (.saveAutoColor(folder: false), "save-auto-color"), (.saveAutoColor(folder: true), "save-auto-color folder"),
            (.saveVibrance(folder: false), "save-vibrance"), (.saveVibrance(folder: true), "save-vibrance folder"),
            (.resetColor(.file), "reset-color file"), (.resetColor(.folder), "reset-color folder"),
        ]
        for (command, text) in commands {
            #expect(Command.parse(text) == command, "\(text)")
            #expect(command.configText == text)
            #expect(Command.parse(command.configText) == command)
            #expect(!command.repeatsWhenHeld && !command.isToggle)
        }
        #expect(Command.parse("save-auto-color elsewhere") == nil)
        #expect(Command.parse("reset-color") == nil)
        #expect(Command.parse("reset-color all") == nil)
    }

    @Test func classicLayoutSavesColourOnShiftAndOptionKeys() {
        let map = InputMap(layout: .classic)
        for (key, command) in [("C", Command.saveAutoColor(folder: false)), ("V", .saveVibrance(folder: false)),
                               ("Alt+c", .saveAutoColor(folder: true)), ("Alt+v", .saveVibrance(folder: true)),
                               ("Meta+C", .saveClip), ("c", .toggleAutoColor), ("v", .toggleVibrance)] {
            #expect(map.command(for: KeyChord.parse(key)!) == command, "\(key)")
        }
    }

    @Test func leftHandLayoutHasNoColourSavesOrResets() {
        let map = InputMap(layout: .leftHand)
        #expect(map.command(for: KeyChord.parse("b")!) == .saveClip)
        #expect(!map.bindings.values.contains { command in
            switch command { case .saveAutoColor, .saveVibrance, .resetColor: return true; default: return false }
        })
    }

    @Test func parsesTheBacklogCommands() {
        #expect(Command.parse("keyframe-step") == .keyframeStep)
        #expect(Command.parse("keyframe-back-step") == .keyframeBackStep)
        #expect(Command.parse("revert-seek") == .revertSeek)
        #expect(Command.parse("cycle ontop") == .cycleOntop)
        #expect(Command.keyframeStep.repeatsWhenHeld && Command.keyframeBackStep.repeatsWhenHeld)
        #expect(!Command.revertSeek.repeatsWhenHeld && !Command.cycleOntop.repeatsWhenHeld)
    }

    @Test func bindsTheSceneCommands() {
        let map = InputMap()
        #expect(map.command(for: KeyChord(key: "UP", modifiers: .shift)) == .sceneStep)
        #expect(map.command(for: KeyChord(key: "DOWN", modifiers: .shift)) == .sceneBackStep)
        #expect(Command.parse("scene-step") == .sceneStep && Command.parse("scene-back-step") == .sceneBackStep)
        for command in [Command.sceneStep, .sceneBackStep] {
            #expect(Command.parse(command.configText) == command)
            #expect(!command.repeatsWhenHeld)
        }
    }

    @Test func pluginActionParsesAndRoundTrips() {
        #expect(Command.parse("plugin-action mark") == .pluginAction("mark"))
        #expect(Command.pluginAction("next-2_b").configText == "plugin-action next-2_b")
        #expect(Command.parse(Command.pluginAction("next").configText) == .pluginAction("next"))
        #expect(!Command.pluginAction("mark").repeatsWhenHeld)
        #expect(!Command.pluginAction("mark").isToggle)
        for bad in ["plugin-action", "plugin-action A", "plugin-action " + String(repeating: "a", count: 33),
                    "plugin-action a b", "plugin-action m.k"] {
            #expect(Command.parse(bad) == nil, "\(bad)")
        }
        var map = InputMap()
        #expect(map.apply("Alt+9 plugin-action mark").isEmpty)
        #expect(map.command(for: KeyChord.parse("Alt+9")!) == .pluginAction("mark"))
    }

    @Test func noBuiltInLayoutBindsAPluginAction() {
        for layout: KeyLayout in [.classic, .leftHand] {
            #expect(!InputMap(layout: layout).bindings.values.contains { if case .pluginAction = $0 { true } else { false } })
        }
    }

    @Test func onlyContinuousCommandsRepeatWhenHeld() {
        for command: Command in [.seek(5, .byConfig), .frameStep, .frameBackStep, .multiplySpeed(1.1),
                                 .setSpeed(1), .addVolume(2)] {
            #expect(command.repeatsWhenHeld, "\(command)")
        }
        for command: Command in [.cyclePause, .cycleMute, .cycleFullscreen, .setFullscreen(false), .abLoop,
                                 .screenshot, .exportRange, .saveClip, .stats, .showProgress, .quit] {
            #expect(!command.repeatsWhenHeld, "\(command)")
        }
    }

    @Test func defaultConfigParsesCleanly() {
        var map = InputMap(layout: .classic)
        #expect(map.apply(InputMap.defaultConfig, source: "default").isEmpty)
    }

    @Test func userFileOverridesAndExtends() {
        var map = InputMap(layout: .classic)
        let warnings = map.apply("""
        s ignore
        RIGHT no-osd seek 10 exact
        Ctrl+e export-range
        x launch-rockets
        """)
        #expect(map.command(for: KeyChord(key: "s")) == nil)
        #expect(map.command(for: KeyChord(key: "RIGHT")) == .seek(10, .exact))
        #expect(map.command(for: KeyChord(key: "e", modifiers: .ctrl)) == .exportRange)
        #expect(warnings.count == 1)
        #expect(warnings[0].contains("input.conf:4"))
    }

    @Test func parsesKeyChords() {
        #expect(KeyChord.parse("Shift+s") == KeyChord(key: "S"))
        #expect(KeyChord.parse("Ctrl++") == KeyChord(key: "+", modifiers: .ctrl))
        #expect(KeyChord.parse("space") == KeyChord(key: "SPACE"))
        #expect(KeyChord.parse("Shift+LEFT") == KeyChord(key: "LEFT", modifiers: .shift))
        #expect(KeyChord.parse("Hyper+x") == nil)
    }

    @Test func mapsKeyEvents() {
        #expect(KeyChord.fromKeyEvent(keyCode: 123, characters: nil, modifiers: []) == KeyChord(key: "LEFT"))
        #expect(KeyChord.fromKeyEvent(keyCode: 49, characters: " ", modifiers: []) == KeyChord(key: "SPACE"))
        #expect(KeyChord.fromKeyEvent(keyCode: 1, characters: "S", modifiers: .shift) == KeyChord(key: "S"))
        #expect(KeyChord.fromKeyEvent(keyCode: 1, characters: "s", modifiers: .meta) == KeyChord(key: "s", modifiers: .meta))
        #expect(KeyChord.fromKeyEvent(keyCode: 100, characters: nil, modifiers: []) == KeyChord(key: "F8"))
        #expect(KeyChord.fromKeyEvent(keyCode: 999, characters: nil, modifiers: []) == nil)
    }

    @Test func parsesCommands() {
        #expect(Command.parse("no-osd seek 5 exact") == .seek(5, .exact))
        #expect(Command.parse("seek 5 keyframes") == .seek(5, .keyframes))
        #expect(Command.parse("scrub fast invert") == .scrub(fast: true, invert: true))
        #expect(Command.parse("scrub sideways") == nil)
        #expect(Command.parse("zoom") == .zoom(nil))
        #expect(Command.parse("set window-scale 0") == nil)
        #expect(Command.parse("set fullscreen no") == .setFullscreen(false))
        #expect(Command.parse("multiply speed 1/2") == .multiplySpeed(0.5))
        #expect(Command.parse("step-speed up") == .stepSpeed(1) && Command.parse("step-speed down") == .stepSpeed(-1))
        #expect(Command.stepSpeed(1).configText == "step-speed up" && Command.stepSpeed(-1).repeatsWhenHeld)
        #expect(Command.parse("script-binding stats/display-stats-toggle") == .stats)
        #expect(Command.parse("screenshot video") == .screenshot)
        #expect(Command.parse("frobnicate") == nil)
        #expect(Command.parse("seek") == nil)
    }

    @Test func stripsTabPrecededComments() {
        var map = InputMap(layout: .classic)
        let warnings = map.apply("s screenshot\t# comment\n")
        #expect(warnings.isEmpty)
        #expect(map.command(for: KeyChord(key: "s")) == .screenshot)
    }

    @Test func configTextRoundTripsEveryDefaultBinding() {
        for command in InputMap(layout: .classic).bindings.values {
            #expect(Command.parse(command.configText) == command, "\(command.configText)")
        }
    }

    @Test func classicLayoutIsTodaysDefaults() {
        let map = InputMap(layout: .classic)
        #expect(map.command(for: KeyChord(key: "l")) == .abLoop)
        #expect(map.command(for: KeyChord(key: "k")) == .markSnap)
        #expect(map.command(for: KeyChord.parse("Meta+C")!) == .saveClip)
        #expect(map.command(for: KeyChord(key: "q")) == .quit)
        #expect(map.bindings.count == 130)   // ⇧C ⇧V ⌥C ⌥V and ⌘⇧C for clips, then the original 88 lines, the middle button and its wheel volume, the shuttle on ⌃J ⌃K ⌃L, 8 right button + scroll, ⌥m, ⇧⌥m, ⌥l, ⇧↑ ⇧↓, ⌥ + wheel volume, 16 MX / side button lines, ⌘W
        #expect(map.command(for: KeyChord.parse("Ctrl+j")!) == .shuttleBack)
        #expect(map.command(for: KeyChord.parse("Ctrl+k")!) == .shuttleStop)
        #expect(map.command(for: KeyChord.parse("Ctrl+l")!) == .shuttleForward)
        #expect(!map.bindings.keys.contains { map.isSecondary($0) })
    }

    @Test func leftHandLayoutMatchesTheSpecTable() {
        let map = InputMap(layout: .leftHand)
        let expected: [(String, Command)] = [
            ("SPACE", .cyclePause), ("q", .frameBackStep), ("e", .frameStep),
            ("Q", .keyframeBackStep), ("E", .keyframeStep), ("w", .holdSpeed),
            ("z", .seek(-5, .byConfig)), ("c", .seek(5, .byConfig)),
            ("Z", .seek(-60, .byConfig)), ("C", .seek(60, .byConfig)),
            ("Alt+z", .seek(-1, .exact)), ("Alt+c", .seek(1, .exact)),
            ("Alt+Z", .sceneBackStep), ("Alt+C", .sceneStep),
            ("x", .revertSeek), ("g", .goTo), ("f", .abLoop), ("F", .cycleABLoopMode),
            ("r", .markIn), ("t", .markOut), ("R", .markPrev), ("T", .markNext),
            ("Alt+r", .markSnap), ("Alt+f", .markLoop), ("X", .markDelete), ("Alt+x", .markClear),
            ("B", .playMarks), ("b", .saveClip), ("v", .screenshot), ("V", .exportRange),
            ("1", .playlistPrev), ("2", .playlistNext),
            ("3", .stepSpeed(-1)), ("4", .stepSpeed(1)), ("5", .setSpeed(1)),
            ("TAB", .togglePlaylist), ("F9", .cyclePlaylistSort), ("Meta+f", .playlistFilter),
            ("`", .cycleFullscreen), ("Meta+t", .cycleOntop),
            ("Alt+a", .cycleAspect), ("Alt+v", .toggleVibrance), ("Alt+V", .toggleAutoColor),
            ("u", .toggleUpscaler), ("U", .cycleUpscaler), ("9", .addVolume(-2)), ("0", .addVolume(2)),
            ("m", .cycleMute), ("i", .stats), ("o", .showProgress), ("?", .showKeys),
            ("Meta+c", .copyFrame), ("Meta+O", .revealFrames), ("Meta+g", .goTo), ("Meta+BS", .deleteFile),
            ("ESC", .setFullscreen(false)), ("MBTN_LEFT_DBL", .cycleFullscreen), ("MBTN_MID", .cycleFullscreen),
            ("MBTN_RIGHT", .cyclePause),
            // the right-half aliases
            ("LEFT", .seek(-5, .byConfig)), ("RIGHT", .seek(5, .byConfig)), ("UP", .seek(60, .byConfig)),
            ("DOWN", .seek(-60, .byConfig)), ("Shift+LEFT", .seek(-1, .exact)), ("Shift+RIGHT", .seek(1, .exact)),
            ("Shift+UP", .sceneStep), ("Shift+DOWN", .sceneBackStep),
            ("Ctrl+LEFT", .keyframeBackStep), ("Alt+RIGHT", .keyframeStep), (",", .frameBackStep), (".", .frameStep),
            ("/", .holdSpeed), ("Shift+BS", .revertSeek), ("PGUP", .playlistPrev), (">", .playlistNext),
            ("[", .stepSpeed(-1)), ("]", .stepSpeed(1)), ("BS", .setSpeed(1)), ("F8", .togglePlaylist),
            // the shuttle
            ("a", .shuttleBack), ("s", .shuttleStop), ("d", .shuttleForward),
            ("j", .shuttleBack), ("k", .shuttleStop), ("l", .shuttleForward),
        ]
        for (spec, command) in expected { #expect(map.command(for: KeyChord.parse(spec)!) == command, "\(spec)") }
        for gone in ["p", "S", "I", "O", "{", "}", "M", "P", "L", "J", "K"] {
            #expect(map.command(for: KeyChord.parse(gone)!) == nil, "\(gone)")
        }
        #expect(map.isSecondary(KeyChord.parse("LEFT")!) && !map.isSecondary(KeyChord.parse("z")!))
        #expect(map.isSecondary(KeyChord(key: "j")) && !map.isSecondary(KeyChord(key: "a")))
        for command in [Command.shuttleBack, .shuttleStop, .shuttleForward] {
            #expect(!command.repeatsWhenHeld && Command.parse(command.configText) == command)
        }
    }

    @Test func leftHandTextsParseCleanlyAndNeverBindAChordTwice() {
        var chords: [KeyChord] = []
        for text in [InputMap.leftHandConfig, InputMap.leftHandSecondaryConfig, InputMap.pointerConfig] {
            var map = InputMap(layout: .classic)
            #expect(map.apply(text, source: "test").isEmpty)
            chords += text.split(separator: "\n").compactMap { KeyChord.parse(String($0.split(separator: " ")[0])) }
        }
        #expect(Set(chords).count == chords.count)
        for command in InputMap(layout: .leftHand).bindings.values {
            #expect(Command.parse(command.configText) == command, "\(command.configText)")
        }
    }

    @Test func everyClassicCommandHasAKeyInLeftHand() {
        let left = Set(InputMap(layout: .leftHand).bindings.values.map(\.configText))
        for command in InputMap(layout: .classic).bindings.values {
            // quit is ⌘Q in the menu; the colour saves are menu items in the left-hand layout
            switch command { case .zoom, .zoomReset, .quit, .saveAutoColor, .saveVibrance: continue; default: break }
            #expect(left.contains(command.configText), "\(command)")
        }
    }

    @Test func pointerBindingsAreTheSameInBothLayouts() {
        let pointer = { (m: InputMap) in m.bindings.filter { $0.key.isPointer } }
        #expect(pointer(InputMap(layout: .leftHand)) == pointer(InputMap(layout: .classic)))
        #expect(!pointer(InputMap(layout: .classic)).isEmpty)
    }

    @Test func inputConfOverridesALeftHandKeyAndASecondaryOne() {
        var map = InputMap(layout: .leftHand)
        map.apply("q ignore\np toggle-playlist\nLEFT seek -10")
        #expect(map.command(for: KeyChord(key: "q")) == nil)
        #expect(map.command(for: KeyChord(key: "p")) == .togglePlaylist)
        #expect(map.command(for: KeyChord(key: "LEFT")) == .seek(-10, .byConfig))
        #expect(!map.isSecondary(KeyChord(key: "LEFT")))
    }

    @Test func optionLettersBindByTheirLetter() {
        // charactersIgnoringModifiers keeps Shift and drops ⌥: ⌥Z arrives as "z", ⌥⇧V as "V".
        #expect(KeyChord.fromKeyEvent(keyCode: 6, characters: "z", modifiers: [.alt]) == KeyChord.parse("Alt+z"))
        #expect(KeyChord.fromKeyEvent(keyCode: 9, characters: "V", modifiers: [.alt, .shift]) == KeyChord.parse("Alt+V"))
    }

    /// extras/tourbox/FrameScrub.tb (scripts/make-tourbox-preset.py) sends these keys: each must reach its command in
    /// the classic layout, or the TourBox breaks silently when the layout changes.
    @Test func tourBoxPresetKeysReachTheirCommands() {
        let map = InputMap(layout: .classic)
        let preset: [(String, Command)] = [
            (",", .frameBackStep), (".", .frameStep), ("Shift+LEFT", .seek(-1, .exact)), ("Shift+RIGHT", .seek(1, .exact)),
            ("[", .stepSpeed(-1)), ("]", .stepSpeed(1)), ("<", .playlistPrev), (">", .playlistNext),
            ("LEFT", .seek(-5, .byConfig)), ("RIGHT", .seek(5, .byConfig)), ("DOWN", .seek(-60, .byConfig)),
            ("UP", .seek(60, .byConfig)), ("9", .addVolume(-2)), ("0", .addVolume(2)),
            ("Ctrl+j", .shuttleBack), ("Ctrl+l", .shuttleForward), ("SPACE", .cyclePause), ("s", .screenshot),
            ("l", .abLoop), ("Meta+c", .copyFrame), ("Shift+BS", .revertSeek), ("S", .exportRange),
            ("BS", .setSpeed(1)), ("f", .cycleFullscreen), ("Meta+O", .revealFrames), ("u", .toggleUpscaler), ("i", .stats),
        ]
        for (spec, command) in preset { #expect(map.command(for: KeyChord.parse(spec)!) == command, "\(spec)") }
    }

    // MARK: Held-button modifiers, _LONG, MX_*

    @Test func heldButtonsAreModifiers() {
        let panel = KeyChord.parse("MX_PANEL+WHEEL_UP")
        #expect(panel == KeyChord(key: "WHEEL_UP", modifiers: .panelButton))
        #expect(panel?.modifiers.contains(.panelButton) == true)
        #expect(KeyChord.parse("MBTN_BACK+WHEEL_UP")?.modifiers == .backButton)
        #expect(KeyChord.parse("MBTN_FORWARD+WHEEL_UP")?.modifiers == .forwardButton)
        #expect(KeyChord.parse("MX_GESTURE+WHEEL_UP")?.modifiers == .gestureButton)
        #expect(KeyChord.parse("MBTN_MID+WHEEL_UP")?.modifiers == .midButton)
        #expect(KeyChord.parse("MBTN_MID") == KeyChord(key: "MBTN_MID"))    // the button itself, not a modifier
        #expect(KeyChord.parse("MBTN_BACK") == KeyChord(key: "MBTN_BACK"))
        #expect(KeyChord.parse("MX_PANEL_LONG") == KeyChord(key: "MX_PANEL_LONG"))
        #expect(KeyChord.parse("mx_gesture+Alt+WHEEL_DOWN") == KeyChord(key: "WHEEL_DOWN", modifiers: [.gestureButton, .alt]))
        #expect(Modifiers.heldButtons == [.backButton, .forwardButton, .panelButton, .gestureButton, .midButton])
        #expect(Modifiers.rightButton.rawValue == 16 && !Modifiers.heldButtons.contains(.rightButton))
    }

    @Test func descriptionRoundTripsInTheFixedOrder() {
        let chord = KeyChord.parse("MBTN_RIGHT+MBTN_BACK+Shift+WHEEL_UP")
        #expect(chord?.modifiers == [.rightButton, .backButton, .shift])
        #expect(chord?.description == "MBTN_RIGHT+MBTN_BACK+Shift+WHEEL_UP")
        let all = KeyChord(key: "WHEEL_UP", modifiers: [.meta, .alt, .ctrl, .shift, .gestureButton, .panelButton,
                                                         .forwardButton, .backButton, .rightButton])
        #expect(all.description == "MBTN_RIGHT+MBTN_BACK+MBTN_FORWARD+MX_PANEL+MX_GESTURE+Shift+Ctrl+Alt+Meta+WHEEL_UP")
        #expect(KeyChord.parse(all.description) == all)
        #expect(KeyChord.parse("MX_BOGUS+WHEEL_UP") == nil)
    }

    @Test func autoColorStrengthAndScrubEdgeCommands() {
        #expect(Command.parse("add auto-color-strength -0.05") == .addAutoColorStrength(-0.05))
        #expect(Command.parse("add auto-color-strength 0.05") == .addAutoColorStrength(0.05))
        #expect(Command.parse("add auto-color-strength") == nil)
        #expect(Command.addAutoColorStrength(-0.05).configText == "add auto-color-strength -0.05")
        #expect(Command.parse(Command.addAutoColorStrength(0.05).configText) == .addAutoColorStrength(0.05))
        #expect(Command.addAutoColorStrength(0.05).repeatsWhenHeld)
        #expect(Command.parse("scrub-edge start") == .scrubEdge(.start))
        #expect(Command.parse("scrub-edge end") == .scrubEdge(.end))
        #expect(Command.parse("scrub-edge middle") == nil)
        #expect(Command.parse("scrub-edge") == nil)
        #expect(Command.scrubEdge(.end).configText == "scrub-edge end")
        #expect(Command.parse(Command.scrubEdge(.start).configText) == .scrubEdge(.start))
    }

    @Test func mouseDefaultsInBothLayouts() {
        let lines: [(String, Command)] = [
            ("WHEEL_UP", .scrub(fast: false, invert: false)), ("WHEEL_DOWN", .scrub(fast: false, invert: false)),
            ("MBTN_RIGHT+WHEEL_UP", .scrub(fast: true, invert: false)), ("MBTN_RIGHT+WHEEL_DOWN", .scrub(fast: true, invert: false)),
            ("MX_GESTURE+WHEEL_UP", .addVolume(2)), ("MX_GESTURE+WHEEL_DOWN", .addVolume(-2)),
            ("Alt+WHEEL_UP", .addVolume(2)), ("Alt+WHEEL_DOWN", .addVolume(-2)),
            ("WHEEL_LEFT", .seek(-10, .byConfig)), ("WHEEL_RIGHT", .seek(10, .byConfig)),
            ("MBTN_RIGHT+WHEEL_LEFT", .stepSpeed(-1)), ("MBTN_RIGHT+WHEEL_RIGHT", .stepSpeed(1)),
            ("MX_PANEL", .toggleAutoColor), ("MX_PANEL_LONG", .toggleVibrance),
            ("MX_PANEL+WHEEL_UP", .addAutoColorStrength(0.05)), ("MX_PANEL+WHEEL_DOWN", .addAutoColorStrength(-0.05)),
            ("MX_GESTURE", .screenshot), ("MX_GESTURE_LONG", .saveClip),
            ("MBTN_BACK", .markIn), ("MBTN_BACK_LONG", .markSnap),
            ("MBTN_BACK+WHEEL_UP", .scrubEdge(.start)), ("MBTN_BACK+WHEEL_DOWN", .scrubEdge(.start)),
            ("MBTN_FORWARD", .markOut), ("MBTN_FORWARD_LONG", .markDelete),
            ("MBTN_FORWARD+WHEEL_UP", .scrubEdge(.end)), ("MBTN_FORWARD+WHEEL_DOWN", .scrubEdge(.end)),
            // kept
            ("Shift+WHEEL_LEFT", .scrub(fast: false, invert: false)), ("Shift+WHEEL_RIGHT", .scrub(fast: false, invert: false)),
            ("Shift+Alt+WHEEL_LEFT", .scrub(fast: true, invert: false)), ("Shift+Alt+WHEEL_RIGHT", .scrub(fast: true, invert: false)),
            ("TRACKPAD_LEFT", .scrub(fast: false, invert: false)), ("TRACKPAD_UP", .addVolume(2)),
        ]
        for layout in [KeyLayout.classic, .leftHand] {
            let map = InputMap(layout: layout)
            for (spec, command) in lines {
                #expect(map.command(for: KeyChord.parse(spec)!) == command, "\(layout) \(spec)")
            }
            #expect(map.command(for: KeyChord(key: "WHEEL_UP")) != .addVolume(2))
        }
    }

    @Test func mouseButtonSideTables() {
        #expect(MouseButton(cid: 0x56) == .forward && MouseButton(cid: 0x53) == .back)
        #expect(MouseButton(cid: 0x01A0) == .panel && MouseButton(cid: 0x00C3) == .gesture && MouseButton(cid: 0x00C4) == .shift)
        #expect(MouseButton(cid: 0x9999) == nil)
        #expect(MouseButton(appKitButtonNumber: 2) == .mid && MouseButton(appKitButtonNumber: 3) == .back
                && MouseButton(appKitButtonNumber: 4) == .forward)
        #expect(MouseButton(appKitButtonNumber: 5) == nil && MouseButton(appKitButtonNumber: 1) == nil)
        #expect(MouseButton.panel.cid == 0x01A0 && MouseButton.gesture.cid == 0x00C3 && MouseButton.shift.cid == 0x00C4)
        #expect(MouseButton.back.cid == nil && MouseButton.back.sideCID == 0x53 && MouseButton.forward.sideCID == 0x56)
        #expect(MouseButton.mid.modifier == .midButton && MouseButton.shift.modifier == nil)
        #expect(MouseButton.back.modifier == .backButton && MouseButton.forward.modifier == .forwardButton)
        #expect(MouseButton.panel.modifier == .panelButton && MouseButton.gesture.modifier == .gestureButton)
        #expect(MouseButton.panel.rawValue == "MX_PANEL" && MouseButton.mid.rawValue == "MBTN_MID")
    }

    @Test func bindsAndHeldChordsAndDivertedButtons() {
        for layout in [KeyLayout.classic, .leftHand] {
            let map = InputMap(layout: layout)
            #expect(map.binds(.back) && map.binds(.back, suffix: "_LONG") && !map.binds(.back, suffix: "_DBL"))
            #expect(map.binds(.panel) && map.binds(.panel, suffix: "_LONG") && map.binds(.gesture, suffix: "_LONG"))
            #expect(!map.binds(.shift) && map.binds(.mid) && !map.binds(.mid, suffix: "_LONG"))
            #expect(map.hasChords(heldWith: .back) && map.hasChords(heldWith: .forward))
            #expect(map.hasChords(heldWith: .panel) && map.hasChords(heldWith: .gesture))
            #expect(map.hasChords(heldWith: .mid) && !map.hasChords(heldWith: .shift))
            #expect(map.divertedCIDs == [0x01A0, 0x00C3], "\(layout)")
        }
        var map = InputMap()
        map.apply("MX_SHIFT screenshot")
        #expect(map.divertedCIDs == [0x01A0, 0x00C3, 0x00C4])
        map.apply("MX_PANEL ignore\nMX_PANEL_LONG ignore\nMX_PANEL+WHEEL_UP ignore\nMX_PANEL+WHEEL_DOWN ignore")
        #expect(map.divertedCIDs == [0x00C3, 0x00C4])
        var held = InputMap()
        held.apply("MX_SHIFT+WHEEL_UP ignore")
        #expect(!held.binds(.shift))
    }

    @Test func togglesAreTheToggleAndCycleCommands() {
        let toggles: [Command] = [.cycleMute, .cycleFullscreen, .cycleOntop, .cycleABLoopMode, .cycleAspect,
                                  .cycleUpscaler, .cyclePlaylistSort, .togglePlaylist, .toggleUpscaler, .toggleVibrance,
                                  .toggleAutoColor, .toggleScrubAudio, .toggleScrubAudioPitch]
        for command in toggles { #expect(command.isToggle, "\(command.configText)") }
        let others: [Command] = [.cyclePause, .setFullscreen(false), .abLoop, .markIn, .screenshot, .stepSpeed(1), .addVolume(2),
                                 .addAutoColorStrength(0.05), .scrubEdge(.start), .playMarks, .playlistNext]
        for command in others { #expect(!command.isToggle, "\(command.configText)") }
    }
}
