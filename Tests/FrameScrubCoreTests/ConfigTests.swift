import Foundation
import LogiHIDPP
import Testing
@testable import FrameScrubCore

@Suite struct ConfigTests {
    /// The README's settings block is the commented reference config: every key, each with its default.
    @Test func readmeSettingsListEveryKeyWithItsDefault() throws {
        let readme = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md"), encoding: .utf8)
        let afterHeading = try #require(readme.components(separatedBy: "`~/.config/framescrub/framescrub.conf`:").dropFirst().first)
        let block = try #require(afterHeading.components(separatedBy: "```").dropFirst().first)
            .components(separatedBy: .newlines).dropFirst().joined(separator: "\n")
        let lines = block.components(separatedBy: .newlines).filter { !$0.isEmpty }
        #expect(lines.map { String($0.prefix { $0 != "=" }) }.sorted() == Config.keys.sorted())
        #expect(lines.allSatisfy { $0.contains(" # ") })
        let (config, warnings) = Config.parse(block)
        #expect(warnings.isEmpty)
        #expect(config == Config())
    }

    @Test func defaultsMatchSpec() {
        let c = Config()
        #expect(c.cacheSizeMiB == 2048)
        #expect(c.scrub == ScrubSettings(pxPerFrame: 8, accelFrom: 20, accelMax: 240, invert: false))
        #expect(c.frameFormat == .jpeg)
        #expect(c.jpegQuality == 95)
        #expect(c.heicQuality == 95)
        #expect(c.frameDirectory == "%{video-dir}/%{video-name}")
        #expect(c.frameTemplate == "%{video-name}_f%{frame:06}_%{time:hh-mm-ss.mmm}")
        #expect(c.exportThreads == 4)
        #expect(c.volume == 100)
        #expect(c.ontop == false)
        #expect(c.statsFontSize == 12)
    }

    @Test func parsesStashKeys() {
        let (c, warnings) = Config.parse(#"""
        stash-url=http://192.0.2.10:9999
        stash-api-key=abc
        stash-path-map=S:\Media=/Volumes/S$/Media;\\server.local\x=/Volumes/x
        start-tab=stash
        """#)
        #expect(warnings.isEmpty)
        #expect(c.stashURL == "http://192.0.2.10:9999")
        #expect(c.stashAPIKey == "abc")
        #expect(c.stashPathMap == #"S:\Media=/Volumes/S$/Media;\\server.local\x=/Volumes/x"#)
        #expect(c.startTab == .stash)
        #expect(c.stashEnabled)
        let (bad, badWarnings) = Config.parse("start-tab=other")
        #expect(badWarnings.count == 1)
        #expect(bad.startTab == .recent)
    }

    @Test func stashOffByDefault() {
        #expect(Config().stashEnabled == false)
        #expect(Config().startTab == .recent)
        #expect(Config.parse("stash-url=not a url").0.stashEnabled == false)
    }

    @Test func parsesPlaylistFontSize() {
        #expect(Config().playlistFontSize == 14)
        let (c, warnings) = Config.parse("playlist-font-size=18")
        #expect(warnings.isEmpty)
        #expect(c.playlistFontSize == 18)
        #expect(c.text(forKey: "playlist-font-size") == "18")
        #expect(Config.parse("playlist-font-size=60").0.playlistFontSize == 14)
    }

    @Test func parsesStartCardSize() {
        #expect(Config().startCardSize == 480)
        let (c, warnings) = Config.parse("start-card-size=640")
        #expect(warnings.isEmpty)
        #expect(c.startCardSize == 640)
        #expect(c.text(forKey: "start-card-size") == "640")
        #expect(Config.parse("start-card-size=140").0.startCardSize == 140)
        #expect(Config.parse("start-card-size=800").0.startCardSize == 800)
        let (low, lowWarnings) = Config.parse("start-card-size=100")
        #expect(low.startCardSize == 480 && !lowWarnings.isEmpty)
        #expect(Config.parse("start-card-size=900").0.startCardSize == 480)
    }

    @Test func parsesHomeLayout() {
        #expect(Config().homeLayout == .fit)
        #expect(Config().text(forKey: "home-layout") == "fit")
        let (c, warnings) = Config.parse("home-layout=scroll")
        #expect(warnings.isEmpty && c.homeLayout == .scroll)
        let (bad, badWarnings) = Config.parse("home-layout=grid")
        #expect(bad.homeLayout == .fit && !badWarnings.isEmpty)
    }

    @Test func parsesStatsFontSize() {
        let (c, warnings) = Config.parse("stats-font-size=18")
        #expect(warnings.isEmpty)
        #expect(c.statsFontSize == 18)
        #expect(c.text(forKey: "stats-font-size") == "18")
        let (bad, badWarnings) = Config.parse("stats-font-size=200")
        #expect(bad.statsFontSize == 12)
        #expect(badWarnings.count == 1)
    }

    @Test func parsesHoldSpeed() {
        #expect(Config().holdSpeed == 2)
        let (c, warnings) = Config.parse("hold-speed=3.5")
        #expect(warnings.isEmpty)
        #expect(c.holdSpeed == 3.5)
        #expect(c.text(forKey: "hold-speed") == "3.5")
        let (bad, badWarnings) = Config.parse("hold-speed=0")
        #expect(bad.holdSpeed == 2)
        #expect(badWarnings.count == 1)
    }

    @Test func parsesColorCorrection() {
        let defaults = Config()
        #expect(defaults.vibrance == 0.5)
        #expect(!defaults.vibranceOn)
        #expect(!defaults.saveColor)
        #expect(!defaults.autoColor)
        let (c, warnings) = Config.parse("vibrance=0.8\nvibrance-on=yes\nsave-color=yes\nauto-color=yes")
        #expect(warnings.isEmpty)
        #expect(c.vibrance == 0.8 && c.vibranceOn && c.saveColor && c.autoColor)
        #expect(c.text(forKey: "auto-color") == "yes")
        #expect(c.text(forKey: "vibrance") == "0.8")
        #expect(c.text(forKey: "vibrance-on") == "yes")
        #expect(c.text(forKey: "save-color") == "yes")
        let (bad, badWarnings) = Config.parse("vibrance=1.5")
        #expect(bad.vibrance == 0.5)
        #expect(badWarnings.count == 1)
    }

    @Test func parsesAutoColorFull() {
        #expect(Config().autoColorFull == 12)
        #expect(Config().text(forKey: "auto-color-full") == "12")
        let (zero, zeroWarnings) = Config.parse("auto-color-full=0")
        #expect(zeroWarnings.isEmpty && zero.autoColorFull == 0)
        let (bad, badWarnings) = Config.parse("auto-color-full=51")
        #expect(bad.autoColorFull == 12 && badWarnings.count == 1)
    }

    @Test func parsesAutoColorThreshold() {
        #expect(Config().autoColorThreshold == 6)
        #expect(Config().text(forKey: "auto-color-threshold") == "6")
        let (zero, zeroWarnings) = Config.parse("auto-color-threshold=0")
        #expect(zeroWarnings.isEmpty && zero.autoColorThreshold == 0)
        #expect(Config.parse("auto-color-threshold=12.5").0.autoColorThreshold == 12.5)
        let (bad, badWarnings) = Config.parse("auto-color-threshold=51")
        #expect(bad.autoColorThreshold == 6 && badWarnings.count == 1)
    }

    @Test func parsesAutoColorSettings() {
        let defaults = Config()
        #expect(defaults.autoColorStrength == 1)
        #expect(defaults.autoColorFilters == Set(AutoColorFilter.allCases))
        #expect(defaults.text(forKey: "auto-color-filters") == "curve,shadows,vibrance")
        let (c, warnings) = Config.parse("auto-color-strength=0.6\nauto-color-filters=shadows, curve")
        #expect(warnings.isEmpty)
        #expect(c.autoColorStrength == 0.6)
        #expect(c.autoColorFilters == [.curve, .shadows])
        #expect(c.text(forKey: "auto-color-filters") == "curve,shadows")
        let (none, noneWarnings) = Config.parse("auto-color-filters=none")
        #expect(noneWarnings.isEmpty && none.autoColorFilters.isEmpty)
        #expect(none.text(forKey: "auto-color-filters") == "none")
        let (bad, badWarnings) = Config.parse("auto-color-filters=curve,saturation\nauto-color-strength=2")
        #expect(bad.autoColorFilters == Set(AutoColorFilter.allCases) && bad.autoColorStrength == 1)
        #expect(badWarnings.count == 2)
        #expect(Config().autoColorInterval == 0)
        let (interval, intervalWarnings) = Config.parse("auto-color-interval=5\nauto-color-interval=-1")
        #expect(interval.autoColorInterval == 5 && intervalWarnings.count == 1)
        #expect(interval.text(forKey: "auto-color-interval") == "5")
        #expect(Config().autoColorVibranceGain == 1)
        let (gain, gainWarnings) = Config.parse("auto-color-vibrance-gain=4\nauto-color-vibrance-gain=0.5")
        #expect(gain.autoColorVibranceGain == 4 && gainWarnings.count == 1)
        #expect(gain.text(forKey: "auto-color-vibrance-gain") == "4")
    }

    @Test func parsesMouseSettings() {
        let d = Config()
        #expect(d.mouseLongPress == 400 && d.mouseHaptics && d.hapticStrength == nil && d.hapticStrongStrength == 80)
        #expect(d.mxPanelForce == .percent(0) && d.mxSideButtons == .watch)
        let (c, warnings) = Config.parse("haptic-end=knock\nmouse-long-press=150\nhaptic-strength=30\nhaptic-strong-strength=100\nmx-panel-force=default\nmx-side-buttons=Take\nmouse-haptics=no\nhaptic-mark=none")
        #expect(warnings.isEmpty)
        #expect(c.haptics.choice(for: .end) == HapticChoice(pattern: .knock, strong: false))
        #expect(c.haptics.choice(for: .mark) == nil && c.text(forKey: "haptic-mark") == "none")
        #expect(c.mouseLongPress == 150 && !c.mouseHaptics && c.hapticStrength == 30 && c.hapticStrongStrength == 100)
        #expect(c.mxPanelForce == .factoryDefault && c.mxSideButtons == .take)
        let (strong, _) = Config.parse("haptic-step=Sharp_Collision strong")
        #expect(strong.haptics.choice(for: .step) == HapticChoice(pattern: .sharpCollision, strong: true))
        let (kept, keptWarnings) = Config.parse("haptic-strength=30\nhaptic-strength=keep")
        #expect(kept.hapticStrength == nil && keptWarnings.isEmpty)
        let (force, forceWarnings) = Config.parse("mx-panel-force=65")
        #expect(force.mxPanelForce == .percent(65) && forceWarnings.isEmpty)
    }

    @Test func rejectsBadMouseSettings() {
        let (c, warnings) = Config.parse("""
            haptic-end=nope
            haptic-step=strong
            mouse-long-press=100
            mouse-long-press=2001
            haptic-strength=101
            haptic-strong-strength=keep
            mx-panel-force=101
            mx-side-buttons=grab
            mouse-haptics=maybe
            """)
        #expect(warnings.count == 9)
        #expect(warnings.first == "framescrub.conf:1: bad option 'haptic-end=nope'")
        #expect(c == Config())
    }

    @Test func mouseSettingsTextRoundTrips() {
        var c = Config()
        c.mouseLongPress = 700
        c.mouseHaptics = false
        c.haptics.choices[.toggle] = .some(nil)
        c.haptics.choices[.done] = HapticChoice(pattern: .knock, strong: true)
        c.hapticStrength = 55
        c.hapticStrongStrength = 95
        c.mxPanelForce = .percent(12)
        c.mxSideButtons = .system
        let keys = ["mouse-long-press", "mouse-haptics"] + HapticEvent.allCases.map(\.configKey)
            + ["haptic-strength", "haptic-strong-strength", "mx-panel-force", "mx-side-buttons"]
        let (back, warnings) = Config.parse(keys.map { "\($0)=\(c.text(forKey: $0)!)" }.joined(separator: "\n"))
        #expect(warnings.isEmpty && back == c)
        for k in keys { #expect(Config().text(forKey: k) != nil, "\(k)") }
    }

    @Test func parsesSpeedStep() {
        #expect(Config().scrub.accelerate)
        #expect(!Config().wheelPrecision)
        let (precision, precisionWarnings) = Config.parse("wheel-precision=yes")
        #expect(precisionWarnings.isEmpty && precision.wheelPrecision && precision.text(forKey: "wheel-precision") == "yes")
        #expect(Config().scrub.precisionFramesPerNotch == 6)
        let (slow, slowWarnings) = Config.parse("wheel-precision-frames=2.5\nwheel-precision-frames=0.2\nwheel-precision-frames=7")
        #expect(slow.scrub.precisionFramesPerNotch == 2.5 && slowWarnings.count == 2)
        #expect(slow.text(forKey: "wheel-precision-frames") == "2.5")
        let (accel, accelWarnings) = Config.parse("scrub-accel-from=2\nscrub-accel-max=5000\nscrub-accel-threshold=300\nscrub-max-multiplier=12")
        #expect(accel.scrub.accelFrom == 20 && accel.scrub.accelMax == 240 && accelWarnings.count == 4)   // out of range; old keys gone
        #expect(Config().scrub.precisionMode == .frames && Config().scrub.precisionMsPerNotch == 100)
        let (time, timeWarnings) = Config.parse("wheel-precision-mode=fps\nwheel-precision-time=60\nwheel-precision-time=10\nwheel-precision-mode=seconds")
        #expect(time.scrub.precisionMode == .fps && time.scrub.precisionMsPerNotch == 60 && timeWarnings.count == 2)
        #expect(time.text(forKey: "wheel-precision-mode") == "fps" && time.text(forKey: "wheel-precision-time") == "60")
        let (noAccel, noAccelWarnings) = Config.parse("scrub-accel=no")
        #expect(noAccelWarnings.isEmpty && !noAccel.scrub.accelerate && noAccel.text(forKey: "scrub-accel") == "no")
        #expect(Config().scrubAudio && Config().scrubAudioLengthMs == 80)
        let (audio, audioWarnings) = Config.parse("scrub-audio=no\nscrub-audio-length=120")
        #expect(audioWarnings.isEmpty && !audio.scrubAudio && audio.scrubAudioLengthMs == 120)
        #expect(audio.text(forKey: "scrub-audio") == "no" && audio.text(forKey: "scrub-audio-length") == "120")
        #expect(Config.parse("scrub-audio-length=10").1.count == 1 && Config.parse("scrub-audio-length=600").1.count == 1)
        #expect(Config().scrubAudioPitch == .tape)
        let (pitch, pitchWarnings) = Config.parse("scrub-audio-pitch=natural")
        #expect(pitchWarnings.isEmpty && pitch.scrubAudioPitch == .natural && pitch.text(forKey: "scrub-audio-pitch") == "natural")
        let (badPitch, badPitchWarnings) = Config.parse("scrub-audio-pitch=high")
        #expect(badPitchWarnings.count == 1 && badPitch.scrubAudioPitch == .tape)
        #expect(Config().speedStep == 0.25)
        let (c, warnings) = Config.parse("speed-step=0.1")
        #expect(warnings.isEmpty && c.speedStep == 0.1 && c.text(forKey: "speed-step") == "0.1")
        #expect(!Config.parse("speed-step=0").1.isEmpty && !Config.parse("speed-step=5").1.isEmpty)
    }

    @Test func parsesKeyLayout() {
        #expect(Config().keyLayout == .classic)
        let (c, warnings) = Config.parse("key-layout=classic")
        #expect(warnings.isEmpty)
        #expect(c.keyLayout == .classic)
        #expect(c.text(forKey: "key-layout") == "classic")
        #expect(Config.parse("key-layout=left-hand").0.keyLayout == .leftHand)
        let (bad, badWarnings) = Config.parse("key-layout=right")
        #expect(bad.keyLayout == .classic && badWarnings.count == 1)
        #expect(KeyLayout.leftHand.title == "Left hand" && KeyLayout.classic.title == "Classic")
    }

    @Test func parsesAppIcon() {
        #expect(Config().appIcon == "horse")
        #expect(Config.keys.last == "app-icon")
        for value in [AppIcon.bundle] + AppIcon.alternates + ["my-own_1.2", "~/Pictures/icon.png", "/tmp/My Icon.icns"] {
            var c = Config()
            c.appIcon = value
            let (parsed, warnings) = Config.parse("app-icon=" + c.text(forKey: "app-icon")!)
            #expect(warnings.isEmpty && parsed == c, "\(value)")
        }
        #expect(Config.parse("app-icon=Sunset").0.appIcon == "sunset")
        // A name not in the app is fine: it may be a picture in ~/.config/framescrub/icons.
        #expect(Config.parse("app-icon=unicorn").0.appIcon == "unicorn")
        // Paths keep their case.
        #expect(Config.parse("app-icon=~/Icons/Horse.PNG").0.appIcon == "~/Icons/Horse.PNG")
        let (bad, warnings) = Config.parse("app-icon=two words")
        #expect(bad.appIcon == "horse" && warnings == ["framescrub.conf:1: bad option 'app-icon=two words'"])
    }

    @Test func appIconLooksInTheUserFolderFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundled = URL(fileURLWithPath: "/bundle/AppIcons/sunset.icns")
        func lookup(_ value: String) -> URL? {
            AppIcon.url(for: value, userDirectory: dir) { $0 == "sunset" ? bundled : nil }
        }
        #expect(lookup("sunset") == bundled)
        #expect(lookup("mine") == nil)
        let png = dir.appendingPathComponent("sunset.png")
        try Data().write(to: png)
        #expect(lookup("sunset")?.path == png.path)
        let icns = dir.appendingPathComponent("sunset.icns")
        try Data().write(to: icns)
        #expect(lookup("sunset")?.path == icns.path)
        #expect(lookup(png.path)?.path == png.path)
        #expect(lookup(dir.appendingPathComponent("none.png").path) == nil)
    }

    @Test func parsesABLoopMode() {
        #expect(Config().abLoop == .loop)
        let (c, warnings) = Config.parse("ab-loop=once")
        #expect(warnings.isEmpty)
        #expect(c.abLoop == .once)
        #expect(c.text(forKey: "ab-loop") == "once")
        #expect(!Config.parse("ab-loop=forever").1.isEmpty)
        #expect(ABLoopMode.loop.next == .once && ABLoopMode.once.next == .pingPong && ABLoopMode.pingPong.next == .loop)
    }

    @Test func parsesClipModeAndConfirm() {
        #expect(Config().clipMode == .separate && Config().clipConfirm)
        let (c, warnings) = Config.parse("clip-mode=joined\nclip-confirm=no")
        #expect(warnings.isEmpty)
        #expect(c.clipMode == .joined && !c.clipConfirm)
        #expect(c.text(forKey: "clip-mode") == "joined" && c.text(forKey: "clip-confirm") == "no")
        #expect(!Config.parse("clip-mode=all").1.isEmpty)
    }

    @Test func parsesPlaylistSort() {
        #expect(Config().playlistSort == .name)
        let (c, warnings) = Config.parse("playlist-sort=size")
        #expect(warnings.isEmpty)
        #expect(c.playlistSort == .size)
        #expect(c.text(forKey: "playlist-sort") == "size")
        #expect(!Config.parse("playlist-sort=random").1.isEmpty)
    }

    @Test func parsesOntop() {
        let (c, warnings) = Config.parse("ontop=yes")
        #expect(warnings.isEmpty)
        #expect(c.ontop)
        #expect(c.text(forKey: "ontop") == "yes")
    }

    @Test func parsesAutoplayAndActivateOnOpen() {
        let d = Config()
        #expect(d.autoplay == false && d.activateOnOpen == true)
        #expect(d.text(forKey: "autoplay") == "no" && d.text(forKey: "activate-on-open") == "yes")
        let (c, warnings) = Config.parse("autoplay=yes\nactivate-on-open=no\n")
        #expect(warnings.isEmpty)
        #expect(c.autoplay && !c.activateOnOpen)
        #expect(c.text(forKey: "autoplay") == "yes" && c.text(forKey: "activate-on-open") == "no")
        #expect(Config.parse("autoplay=maybe").1.count == 1)
        #expect(Config.parse("activate-on-open=2").1.count == 1)
        let keys = Config.keys
        #expect(keys.firstIndex(of: "autoplay") == keys.firstIndex(of: "playlist-autoadvance")! + 1)
        #expect(keys.firstIndex(of: "activate-on-open") == keys.firstIndex(of: "autoplay")! + 1)
    }

    @Test func parsesEveryKey() {
        let (c, warnings) = Config.parse("""
        # FrameScrub settings
        cache-size=4096
        scrub-px-per-frame = 12
        scrub-accel-from=30
        scrub-accel-max=600
        scrub-invert=yes
        frame-format=PNG
        jpeg-quality=90   # inline comment
        heic-quality=80
        frame-dir=~/Frames/%{video-name}
        frame-template=%{video-name}-%{frame}
        export-threads=8
        volume=55
        """)
        #expect(warnings.isEmpty)
        #expect(c.cacheSizeMiB == 4096)
        #expect(c.scrub == ScrubSettings(pxPerFrame: 12, accelFrom: 30, accelMax: 600, invert: true))
        #expect(c.frameFormat == .png)
        #expect(c.jpegQuality == 90)
        #expect(c.heicQuality == 80)
        #expect(c.frameDirectory == "~/Frames/%{video-name}")
        #expect(c.frameTemplate == "%{video-name}-%{frame}")
        #expect(c.exportThreads == 8)
        #expect(c.volume == 55)
    }

    @Test func reportsBadLinesAndKeepsDefaults() {
        let (c, warnings) = Config.parse("jpeg-quality=500\nwhatever=1\nnot a pair\nframe-format=gif\n")
        #expect(warnings.count == 4)
        #expect(warnings[0].hasPrefix("framescrub.conf:1"))
        #expect(c == Config())
    }

    @Test func imageFormatExtensions() {
        #expect(ImageFormat.jpeg.fileExtension == "jpg")
        #expect(ImageFormat.heic.fileExtension == "heic")
    }

    @Test func preservesHashInValues() {
        let (c, warnings) = Config.parse("frame-dir=/Users/me/C#/x\n")
        #expect(warnings.isEmpty)
        #expect(c.frameDirectory == "/Users/me/C#/x")
    }

    @Test func stripsSpaceAndTabPrecededComments() {
        let (c1, w1) = Config.parse("jpeg-quality=90 # comment\n")
        #expect(w1.isEmpty)
        #expect(c1.jpegQuality == 90)

        let (c2, w2) = Config.parse("jpeg-quality=90\t# comment\n")
        #expect(w2.isEmpty)
        #expect(c2.jpegQuality == 90)
    }

    @Test func parsesSceneSettings() {
        let d = Config()
        #expect(d.sceneThreshold == 45 && d.sceneLookahead == 30)
        let (c, w) = Config.parse("scene-threshold=32\nscene-lookahead=0\n")
        #expect(w.isEmpty && c.sceneThreshold == 32 && c.sceneLookahead == 0)
        #expect(c.text(forKey: "scene-threshold") == "32" && c.text(forKey: "scene-lookahead") == "0")
        let (bad, warnings) = Config.parse("scene-threshold=300\nscene-lookahead=1001\n")
        #expect(warnings.count == 2)
        #expect(bad.sceneThreshold == 45 && bad.sceneLookahead == 30)
        #expect(Config.keys.firstIndex(of: "scene-threshold") == Config.keys.firstIndex(of: "seek-mode")! + 1)
    }

    @Test func v11DefaultsMatchSpec() {
        let c = Config()
        #expect(c.scrub.fastMultiplier == 10)
        #expect(c.seekMode == .keyframe)
        #expect(c.resumePlayback && c.playlistAutoadvance && c.preview && c.srStill)
        #expect(c.previewWidth == 240)
        #expect(c.exportMode == .all && c.exportEvery == 10 && c.exportFPS == 1 && c.exportScale == 1)
        #expect(c.scaleMode == .auto && c.sharpen == 0.3)
        #expect(c.saveScale == 1 && c.saveUpscaler == .ml)
    }

    @Test func singleInstanceDefaultsOffAndParses() {
        #expect(Config().singleInstance == false)
        let (c, w) = Config.parse("single-instance=yes\n")
        #expect(w.isEmpty && c.singleInstance)
        let (d, w2) = Config.parse("single-instance=maybe\n")
        #expect(w2.count == 1 && !d.singleInstance)
        var e = Config(); e.singleInstance = true
        #expect(e.text(forKey: "single-instance") == "yes")
        #expect(Config().text(forKey: "single-instance") == "no")
    }

    @Test func parsesV11Keys() {
        let (c, warnings) = Config.parse("""
        scrub-fast-multiplier=20
        seek-mode=exact
        resume-playback=no
        playlist-autoadvance=no
        preview=no
        preview-width=320
        export-mode=fps
        export-every=5
        export-fps=2.5
        export-scale=2
        scale=lanczos
        sharpen=0.5
        sr-still=no
        save-scale=4
        save-upscaler=lanczos
        """)
        #expect(warnings.isEmpty)
        #expect(c.scrub.fastMultiplier == 20)
        #expect(c.seekMode == .exact)
        #expect(!c.resumePlayback && !c.playlistAutoadvance && !c.preview && !c.srStill)
        #expect(c.previewWidth == 320)
        #expect(c.exportMode == .fps && c.exportEvery == 5 && c.exportFPS == 2.5 && c.exportScale == 2)
        #expect(c.scaleMode == .lanczos && c.sharpen == 0.5)
        #expect(c.saveScale == 4 && c.saveUpscaler == .lanczos)
    }

    @Test func rejectsBadV11Values() {
        let (c, warnings) = Config.parse("export-scale=3\npreview-width=10\nsharpen=2\nseek-mode=fast\nexport-every=1\n")
        #expect(warnings.count == 5)
        #expect(c == Config())
    }

    @Test func textRoundTripsEveryKey() {
        var c = Config()
        c.cacheSizeMiB = 1024
        c.scrub = ScrubSettings(pxPerFrame: 6, accelFrom: 12.5, accelMax: 400, invert: true, fastMultiplier: 15)
        c.frameFormat = .png
        c.volume = 42.5
        c.seekMode = .exact
        c.exportMode = .every
        c.exportFPS = 0.25
        c.sharpen = 0.75
        c.saveUpscaler = .lanczos
        c.singleInstance = true
        let text = Config.keys.map { "\($0)=\(c.text(forKey: $0)!)" }.joined(separator: "\n")
        let (parsed, warnings) = Config.parse(text)
        #expect(warnings.isEmpty)
        #expect(parsed == c)
    }

    @Test func writeChangesOnlyTheGivenKeys() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("framescrub.conf")
        try "# mine\njpeg-quality=90  # keep\nvolume=50\n".write(to: url, atomically: true, encoding: .utf8)
        var c = Config()
        c.volume = 70
        c.seekMode = .exact
        try c.write(keys: ["volume", "seek-mode"], to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "# mine\njpeg-quality=90  # keep\nvolume=70\nseek-mode=exact\n")
    }

    @Test func writeRefusesUnreadableFileAndLeavesItUntouched() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("framescrub.conf")
        let bytes = Data([0x76, 0x3D, 0xFF, 0xFE, 0x0A])
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try Config().write(keys: ["volume"], to: url) }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func writeCreatesMissingFileWithHeader() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("sub/framescrub.conf")
        try Config().write(keys: ["volume"], to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == ConfigText.header + "\nvolume=100\n")
    }

    @Test func outputSizeKeysAcceptScaleFitAndFixedSides() {
        let (c, warnings) = Config.parse("save-scale=fit\nexport-scale=width:3840\n")
        #expect(warnings.isEmpty)
        #expect(c.saveScale == .fitScreen && c.exportScale == .width(3840))
        let (d, none) = Config.parse("save-scale=height:2160\nexport-scale=4\n")
        #expect(none.isEmpty)
        #expect(d.saveScale == .height(2160) && d.exportScale == .scale(4))
        #expect(c.text(forKey: "save-scale") == "fit" && c.text(forKey: "export-scale") == "width:3840")
    }

    @Test func outputSizeKeysRejectBadValues() {
        let (c, warnings) = Config.parse("save-scale=3\nexport-scale=width:10\nsave-scale=fit2\n")
        #expect(warnings.count == 3)
        #expect(c.saveScale == 1 && c.exportScale == 1)
    }

    @Test func readCacheSetting() {
        #expect(Config().readCacheMiB == 256)
        #expect(Config.parse("read-cache=0").0.readCacheMiB == 0)
        let (c, warnings) = Config.parse("read-cache=5000")
        #expect(warnings.count == 1)
        #expect(c.readCacheMiB == 256)
        #expect(Config().text(forKey: "read-cache") == "256")
    }

    @Test func parsesSharpExportKeys() {
        let defaults = Config()
        #expect(!defaults.exportSharp && defaults.exportSharpThreshold == 80 && defaults.exportSharpNeighbours == 7)
        let (c, warnings) = Config.parse("""
        export-sharp=yes
        export-sharp-threshold=45
        export-sharp-neighbours=9
        """)
        #expect(warnings.isEmpty)
        #expect(c.exportSharp && c.exportSharpThreshold == 45 && c.exportSharpNeighbours == 9)
        #expect(c.text(forKey: "export-sharp") == "yes")
        #expect(c.text(forKey: "export-sharp-threshold") == "45")
        #expect(c.text(forKey: "export-sharp-neighbours") == "9")
        let (bad, badWarnings) = Config.parse("""
        export-sharp-threshold=0
        export-sharp-threshold=101
        export-sharp-neighbours=8
        export-sharp-neighbours=1
        export-sharp-neighbours=33
        """)
        #expect(badWarnings.count == 5)
        #expect(bad.exportSharpThreshold == 80 && bad.exportSharpNeighbours == 7)
    }

    @Test func exportSettingsCarryTheFiltersOnlyWhenOn() {
        var config = Config()
        let off = ExportSettings(config: config)
        #expect(!off.sharpest && off.skipBlurry == nil && off.skipDuplicates == nil)
        config.exportSharp = true
        #expect(ExportSettings(config: config).sharpest && ExportSettings(config: config).skipBlurry == nil)
        config.exportSkipBlurry = true
        config.exportSharpThreshold = 45
        config.exportSharpNeighbours = 9
        #expect(ExportSettings(config: config).skipBlurry == SharpFilter(threshold: 0.45, neighbours: 9))
        config.exportSkipDuplicates = true
        config.exportDuplicateChange = 12
        #expect(ExportSettings(config: config).skipDuplicates == 0.12)
    }

    @Test func parsesBlurryAndDuplicateKeys() {
        let defaults = Config()
        #expect(!defaults.exportSkipBlurry && !defaults.exportSkipDuplicates)
        #expect(defaults.exportDuplicateChange == DuplicateFilter.defaultChange)
        let (c, warnings) = Config.parse("""
        export-skip-blurry=yes
        export-skip-duplicates=yes
        export-duplicate-change=30
        """)
        #expect(warnings.isEmpty)
        #expect(c.exportSkipBlurry && c.exportSkipDuplicates && c.exportDuplicateChange == 30)
        #expect(c.text(forKey: "export-skip-blurry") == "yes")
        #expect(c.text(forKey: "export-duplicate-change") == "30")
        let (_, badWarnings) = Config.parse("export-duplicate-change=0\nexport-duplicate-change=101")
        #expect(badWarnings.count == 2)
    }

    @Test func parsesClipSettings() {
        let defaults = Config()
        #expect(defaults.clipTemplate == "%{video-name}_%{start}_%{end}")
        #expect(defaults.clipReadLimitMB == 40)
        let (c, warnings) = Config.parse("""
        clip-template=%{video-name}_clip
        clip-read-limit=0
        """)
        #expect(warnings.isEmpty)
        #expect(c.clipTemplate == "%{video-name}_clip" && c.clipReadLimitMB == 0)
        #expect(c.text(forKey: "clip-template") == "%{video-name}_clip")
        #expect(c.text(forKey: "clip-read-limit") == "0")
        let (bad, badWarnings) = Config.parse("clip-read-limit=1001\nclip-template=")
        #expect(badWarnings.count == 2)
        #expect(bad.clipTemplate == defaults.clipTemplate && bad.clipReadLimitMB == defaults.clipReadLimitMB)
        let keys = Config.keys
        let after = keys.firstIndex(of: "export-duplicate-change")! + 1
        #expect(Array(keys[after..<after + 2]) == ["clip-template", "clip-read-limit"])
    }

    @Test func exportSettingsCarryTheColorCorrectionOnlyWithSaveColor() {
        var config = Config()
        let color = ColorCorrection(vibrance: 0.7)
        #expect(ExportSettings(config: config, color: color).color.isIdentity)
        config.saveColor = true
        #expect(ExportSettings(config: config, color: color).color.vibrance == 0.7)
        #expect(ExportSettings(config: config).color.isIdentity)
    }

    @Test func parsesHardwareDecoding() {
        #expect(Config().hwdec == .auto)
        let (c, warnings) = Config.parse("hwdec=no")
        #expect(warnings.isEmpty)
        #expect(c.hwdec == .no)
        #expect(c.text(forKey: "hwdec") == "no")
        let (bad, badWarnings) = Config.parse("hwdec=videotoolbox")
        #expect(bad.hwdec == .auto)
        #expect(badWarnings.count == 1)
    }

    @Test func autoDecodesOnVideoToolbox() {
        #expect(HardwareDecoding.auto.prefersHardware)
        #expect(HardwareDecoding.yes.prefersHardware)
        #expect(!HardwareDecoding.no.prefersHardware)
    }
}
