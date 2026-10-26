import Foundation
import LogiHIDPP

/// The event a `haptic-<event>` key belongs to.
private func hapticEvent(forKey key: String) -> HapticEvent? {
    key.hasPrefix("haptic-") ? HapticEvent(rawValue: String(key.dropFirst("haptic-".count))) : nil
}

/// The line without its comment, trimmed. A comment starts at `#` at line start or after whitespace.
func stripComment(_ line: String) -> String {
    let content = commentStart(in: line).map { String(line[..<$0]) } ?? line
    return content.trimmingCharacters(in: .whitespaces)
}

public enum SeekMode: String, Sendable { case keyframe, exact }
public enum ExportMode: String, Sendable { case all, every, fps }
public enum ScaleMode: String, Sendable { case auto, metalfx, lanczos, bilinear }
public enum Upscaler: String, Sendable { case ml, lanczos }

/// What `c` makes of the cut marks (`clip-mode`, cut marks spec §4).
public enum ClipMode: String, CaseIterable, Sendable {
    case separate, joined, inverted

    public var title: String {
        switch self {
        case .separate: "Separate files"
        case .joined: "Joined into one file"
        case .inverted: "Everything except the marked"
        }
    }

    /// Appended to `clip-template`.
    public var nameSuffix: String {
        switch self {
        case .separate: ""
        case .joined: "_joined"
        case .inverted: "_cut"
        }
    }
}

/// How the scrub tape sounds (`scrub-audio-pitch`, ⇧⌥m; scrub audio spec §6б): `tape` — the pitch follows the
/// speed; `natural` — the sound keeps its own pitch from 0.5× up (reversed when scrubbing backward).
public enum ScrubPitch: String, CaseIterable, Sendable {
    case tape
    case natural
}

/// What playback does on reaching B of the A-B range (`ab-loop`; ⇧F, or L in classic, cycles it).
public enum ABLoopMode: String, CaseIterable, Sendable {
    /// Back to A, again and again.
    case loop
    /// Pause on B; playing from B starts over at A.
    case once
    /// Turn around at B and at A (reverse playback spec §3).
    case pingPong = "ping-pong"

    public var next: ABLoopMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var title: String {
        switch self {
        case .loop: "Loop"
        case .once: "Play once, then pause"
        case .pingPong: "Back and forth"
        }
    }
}

/// The default key bindings (`key-layout`): everything frequent under the left hand, or the original mpv-style keys.
public enum KeyLayout: String, CaseIterable, Sendable {
    case leftHand = "left-hand"
    case classic

    public var title: String {
        switch self {
        case .leftHand: "Left hand"
        case .classic: "Classic"
        }
    }
}

/// Where Home opens (`home-tab`): Recent or the Stash library.
public enum HomeTab: String, CaseIterable, Sendable {
    case recent
    case stash
}

/// `hwdec` (as in mpv): VideoToolbox or FFmpeg's software decoders for playback and scrubbing.
public enum HardwareDecoding: String, Sendable {
    case auto, yes, no

    /// `auto` and `yes` decode on VideoToolbox, paused, scrubbing and playing alike: H.264/HEVC through our own
    /// asynchronous session (as fast as software on Apple silicon at a fraction of the CPU time), other codecs through
    /// FFmpeg's hwaccel where it has one. `no` decodes everything in software.
    public var prefersHardware: Bool { self != .no }
}

/// Settings from ~/.config/framescrub/framescrub.conf: mpv-style `key=value`, `#` comments.
public struct Config: Equatable, Sendable {
    public var cacheSizeMiB = 2048
    /// MiB of file data kept in 2 MiB blocks for all decoders of a file; 0 = off.
    public var readCacheMiB = 256
    public var scrub = ScrubSettings()
    /// `wheel-precision`: Logitech mice (HID++) get their high-resolution wheel (Precision Scroll) while the pointer
    /// is over the video in FrameScrub, and their own mode back otherwise.
    public var wheelPrecision = false
    /// `mouse-long-press`: ms a mouse button is held before it counts as a long press.
    public var mouseLongPress = 400
    /// `mouse-haptics`: the MX Master's haptic panel answers keyboard and mouse input.
    public var mouseHaptics = true
    /// `haptic-*`: the pattern each event plays.
    public var haptics = HapticSettings()
    /// `haptic-strength`: the mouse's normal haptic strength in percent; nil = keep what the mouse has.
    public var hapticStrength: Int? = nil
    /// `haptic-strong-strength`: the strength a `strong` pattern plays at, in percent.
    public var hapticStrongStrength = 80
    /// `mx-panel-force`: how hard the haptic panel must be pressed.
    public var mxPanelForce = PanelForceSetting.percent(0)
    /// `mx-side-buttons`: how back / forward reach FrameScrub.
    public var mxSideButtons = SideButtonsMode.watch
    public var frameFormat = ImageFormat.jpeg
    public var jpegQuality = 95
    public var heicQuality = 95
    public var frameDirectory = "%{video-dir}/%{video-name}"
    public var frameTemplate = "%{video-name}_f%{frame:06}_%{time:hh-mm-ss.mmm}"
    public var exportThreads = 4
    public var volume = 100.0
    public var seekMode = SeekMode.keyframe
    /// Candidate threshold of the scene search: how different two keyframes must be to check for a cut between them.
    public var sceneThreshold = 45.0
    /// Keyframes searched ahead for the next scene after a jump (0 = none).
    public var sceneLookahead = 30
    /// Seconds one press may check candidates frame by frame; then keyframes alone decide (0 = keyframes only).
    public var sceneCheckTime = 1.0
    /// Seconds one press may search; then it stops and says how far it looked.
    public var sceneSearchTime = 4.0
    public var hwdec = HardwareDecoding.auto
    /// Gentle reading of network volumes (`NetworkPolicy`).
    public var networkMode = NetworkMode.auto
    public var resumePlayback = true
    public var playlistAutoadvance = true
    /// Start playing every file as it opens (after the resume position is applied).
    public var autoplay = false
    /// Bring the window to the front when a file is opened from Finder or the Dock.
    public var activateOnOpen = true
    public var playlistSort = PlaylistSort.name
    public var playlistFontSize = 14
    /// `home-card-size`: the width of Home's cards in points (⌘= / ⌘− / ⌘0 on Home).
    public var homeCardSize = 220.0
    /// `recent-count`: how many recent videos Home's Recent shows.
    public var recentCount = 50
    /// `home-sidebar`: whether Home shows its sidebar (⌃⌘S).
    public var homeSidebar = true
    public var singleInstance = false
    /// `home-tab`: where Home opens, the user's last choice of Recent or the Stash library.
    public var homeTab = HomeTab.recent
    /// `stash-url`: the Stash server whose WebUI Home shows; empty = no Stash integration.
    public var stashURL = ""
    /// `stash-api-key`: sent as `ApiKey` when Stash has a login.
    public var stashAPIKey = ""
    /// `stash-path-map`: `stashPrefix=localPrefix` rules separated by `;`, tried before the mounted shares.
    public var stashPathMap = ""
    /// `stash-stream`: when a scene plays from Stash's stream instead of its file on a share.
    public var stashStream = StashStreaming.auto
    public var stashEnabled: Bool { URL(string: stashURL)?.host != nil }
    /// `plugin=Name | URL` lines, in file order; a name given twice keeps its first page.
    public var plugins: [PluginEntry] = []
    /// `slot-left` / `slot-right` / `slot-bottom`; a slot without its key keeps `SlotDefaults.standard`'s.
    public var slots = SlotDefaults.standard
    /// `slot-reveal-distance`: how near a side edge (points) the pointer brings a hidden slot (`EdgeReveal.isAt`).
    public var slotRevealDistance = 12
    /// `mouse-profile`: what the mouse's buttons do (`MouseProfile`).
    public var mouseProfile = MouseProfile.viewing
    /// `plugin-open-allowed`: origins (`http://host:port`, comma-separated) whose pages may open local videos.
    public var pluginOpenAllowed = ""
    public var preview = true
    public var previewWidth = 240.0
    public var exportMode = ExportMode.all
    public var exportEvery = 10
    public var exportFPS = 1.0
    public var exportScale: OutputSize = 1
    /// Range export saves the sharpest frame of each window instead of its first (sharp export spec §3).
    public var exportSharp = false
    /// Range export skips a window whose frame is blurrier than its neighbours (sharp export spec §3.2).
    public var exportSkipBlurry = false
    /// Percent of the neighbouring windows' median sharpness a window's frame needs.
    public var exportSharpThreshold = 80
    /// Odd number of windows whose median that threshold is taken of.
    public var exportSharpNeighbours = 7
    /// Range export skips a frame too like the last one it saved.
    public var exportSkipDuplicates = false
    /// Percent of the picture that has to change since the last saved frame.
    public var exportDuplicateChange = DuplicateFilter.defaultChange
    /// File name of an A-B clip (`c`), without the extension; `%{start}` / `%{end}` are the clip's times.
    public var clipTemplate = "%{video-name}_%{start}_%{end}"
    /// MB/s a clip may read from the file, so playback keeps the network; 0 = no limit.
    public var clipReadLimitMB = 40
    /// What `c` saves (the last choice in its sheet).
    public var clipMode = ClipMode.separate
    /// `c` asks how to save (separate, joined, inverted); no = straight to `clipMode`.
    public var clipConfirm = true
    public var scaleMode = ScaleMode.auto
    public var sharpen = 0.3
    public var srStill = true
    public var saveScale: OutputSize = 1
    public var saveUpscaler = Upscaler.ml
    /// Strength of the on-screen vibrance (`v` turns it on and off), 0…1.
    public var vibrance = 0.5
    public var vibranceOn = false
    /// 0…1: how much of the automatic colour adjustments (`V`) is applied.
    public var autoColorStrength = 1.0
    /// Auto colour (`V`) stays on for the following files: each one is analysed from its first frame with a picture.
    public var autoColor = false
    public var autoColorFilters = Set(AutoColorFilter.allCases)
    /// Multiplies the vibrance the auto colour analysis chooses, 1…8.
    public var autoColorVibranceGain = 1.0
    /// Seconds of video after which auto colour is computed again from the frame on screen; 0 = only on `V`.
    public var autoColorInterval = 0.0
    /// A scene gets auto colour only if the full correction changes it by at least this much (mean difference
    /// 0…255, 0…50); 0 corrects every scene.
    public var autoColorThreshold = 6.0
    /// Δ at which a scene gets the whole `autoColorStrength`; between the threshold and this it ramps up (0…50,
    /// 0 = the whole strength from the threshold).
    public var autoColorFull = 12.0
    /// Saved and copied frames get the on-screen colour correction too.
    public var saveColor = false
    /// The player window floats above other apps' windows.
    public var ontop = false
    /// Points; the text of the stats overlay (`i`).
    public var statsFontSize = 12
    /// Speed while the hold-speed key (`/`) is held.
    public var holdSpeed = 2.0
    /// `keep-speed`: the speed chosen with `[` / `]` (or `set speed`) stays for the next file opened in the window;
    /// the direction, the shuttle's speeds and a hold-speed in progress do not. `no`: every file starts at 1×.
    public var keepSpeed = true
    /// What `[` / `]` (step-speed) add to or take from the speed.
    public var speedStep = 0.25
    /// A short piece of sound on every frame change in pause (`⌥m` toggles it).
    public var scrubAudio = true
    /// Milliseconds, the length of that piece.
    public var scrubAudioLengthMs = 80
    /// How the scrub tape sounds: its pitch follows the speed, or stays the sound's own (spec §6б).
    public var scrubAudioPitch = ScrubPitch.tape
    public var abLoop = ABLoopMode.loop
    /// `segment-advance`: when a locked segment ends, play it again (`repeat`) or go on to the next one (`next`).
    public var segmentAdvance = SegmentAdvance.repeating
    public var keyLayout = KeyLayout.classic
    /// `app-icon`: which icon the Dock shows (see `AppIcon`).
    public var appIcon = AppIcon.bundle

    public init() {}

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/framescrub", isDirectory: true)
    }

    public static var fileURL: URL { directory.appendingPathComponent("framescrub.conf") }

    /// Every key `framescrub.conf` understands, in file order.
    public static let keys = [
        "cache-size", "read-cache", "volume", "resume-playback", "playlist-autoadvance", "autoplay", "activate-on-open", "playlist-sort", "playlist-font-size", "home-card-size", "recent-count", "home-sidebar", "single-instance", "home-tab", "stash-url", "stash-api-key", "stash-path-map", "stash-stream", "plugin-open-allowed", "slot-left", "slot-right", "slot-bottom", "slot-reveal-distance", "mouse-profile", "seek-mode", "scene-threshold", "scene-lookahead", "scene-check-time", "scene-search-time", "hwdec", "network-mode",
        "scrub-px-per-frame", "scrub-accel-from", "scrub-accel-max", "scrub-invert", "scrub-fast-multiplier", "scrub-accel", "wheel-precision", "wheel-precision-mode", "wheel-precision-frames", "wheel-precision-time",
        "mouse-long-press", "mouse-haptics", "haptic-step", "haptic-detent", "haptic-limit", "haptic-long-armed", "haptic-toggle", "haptic-end", "haptic-keyframe", "haptic-mark", "haptic-done", "haptic-error", "haptic-strength", "haptic-strong-strength", "mx-panel-force", "mx-side-buttons",
        "frame-format", "jpeg-quality", "heic-quality", "frame-dir", "frame-template", "export-threads",
        "export-mode", "export-every", "export-fps", "export-scale", "export-sharp", "export-skip-blurry", "export-sharp-threshold", "export-sharp-neighbours",
        "export-skip-duplicates", "export-duplicate-change", "clip-template", "clip-read-limit", "clip-mode", "clip-confirm",
        "preview", "preview-width", "scale", "sharpen", "sr-still", "save-scale", "save-upscaler",
        "vibrance", "vibrance-on", "auto-color", "auto-color-strength", "auto-color-filters", "auto-color-vibrance-gain", "auto-color-interval", "auto-color-threshold", "auto-color-full", "save-color", "ontop", "stats-font-size",
        "hold-speed", "speed-step", "keep-speed", "scrub-audio", "scrub-audio-length", "scrub-audio-pitch", "ab-loop", "segment-advance", "key-layout",
        "app-icon",
    ]

    /// The value of `key` as it is written in the file.
    public func text(forKey key: String) -> String? {
        func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }
        switch key {
        case "cache-size": return String(cacheSizeMiB)
        case "read-cache": return String(readCacheMiB)
        case "volume": return formatNumber(volume)
        case "resume-playback": return yesNo(resumePlayback)
        case "playlist-autoadvance": return yesNo(playlistAutoadvance)
        case "autoplay": return yesNo(autoplay)
        case "activate-on-open": return yesNo(activateOnOpen)
        case "playlist-sort": return playlistSort.rawValue
        case "playlist-font-size": return String(playlistFontSize)
        case "home-card-size": return formatNumber(homeCardSize)
        case "recent-count": return String(recentCount)
        case "home-sidebar": return yesNo(homeSidebar)
        case "single-instance": return yesNo(singleInstance)
        case "home-tab": return homeTab.rawValue
        case "stash-url": return stashURL
        case "stash-api-key": return stashAPIKey
        case "stash-path-map": return stashPathMap
        case "stash-stream": return stashStream.rawValue
        case "plugin-open-allowed": return pluginOpenAllowed
        case _ where SlotEdge.allCases.contains(where: { $0.key == key }):
            return slots[SlotEdge.allCases.first { $0.key == key }!]?.text
        case "slot-reveal-distance": return String(slotRevealDistance)
        case "mouse-profile": return mouseProfile.rawValue
        case "seek-mode": return seekMode.rawValue
        case "scene-threshold": return formatNumber(sceneThreshold)
        case "scene-lookahead": return String(sceneLookahead)
        case "scene-check-time": return formatNumber(sceneCheckTime)
        case "scene-search-time": return formatNumber(sceneSearchTime)
        case "hwdec": return hwdec.rawValue
        case "network-mode": return networkMode.rawValue
        case "scrub-px-per-frame": return formatNumber(scrub.pxPerFrame)
        case "scrub-accel-from": return formatNumber(scrub.accelFrom)
        case "scrub-accel-max": return formatNumber(scrub.accelMax)
        case "scrub-invert": return yesNo(scrub.invert)
        case "scrub-accel": return yesNo(scrub.accelerate)
        case "wheel-precision": return yesNo(wheelPrecision)
        case "wheel-precision-mode": return scrub.precisionMode.rawValue
        case "wheel-precision-frames": return formatNumber(scrub.precisionFramesPerNotch)
        case "wheel-precision-time": return formatNumber(scrub.precisionMsPerNotch)
        case "mouse-long-press": return String(mouseLongPress)
        case "mouse-haptics": return yesNo(mouseHaptics)
        case "haptic-strength": return hapticStrength.map(String.init) ?? "keep"
        case "haptic-strong-strength": return String(hapticStrongStrength)
        case "mx-panel-force": return mxPanelForce.text
        case "mx-side-buttons": return mxSideButtons.rawValue
        case _ where hapticEvent(forKey: key) != nil: return HapticChoice.text(haptics.choice(for: hapticEvent(forKey: key)!))
        case "scrub-fast-multiplier": return formatNumber(scrub.fastMultiplier)
        case "frame-format": return frameFormat.rawValue
        case "jpeg-quality": return String(jpegQuality)
        case "heic-quality": return String(heicQuality)
        case "frame-dir": return frameDirectory
        case "frame-template": return frameTemplate
        case "export-threads": return String(exportThreads)
        case "export-mode": return exportMode.rawValue
        case "export-every": return String(exportEvery)
        case "export-fps": return formatNumber(exportFPS)
        case "export-scale": return exportScale.text
        case "export-sharp": return yesNo(exportSharp)
        case "export-sharp-threshold": return String(exportSharpThreshold)
        case "export-sharp-neighbours": return String(exportSharpNeighbours)
        case "export-skip-blurry": return yesNo(exportSkipBlurry)
        case "export-skip-duplicates": return yesNo(exportSkipDuplicates)
        case "export-duplicate-change": return String(exportDuplicateChange)
        case "clip-template": return clipTemplate
        case "clip-read-limit": return String(clipReadLimitMB)
        case "clip-mode": return clipMode.rawValue
        case "clip-confirm": return yesNo(clipConfirm)
        case "preview": return yesNo(preview)
        case "preview-width": return formatNumber(previewWidth)
        case "scale": return scaleMode.rawValue
        case "sharpen": return formatNumber(sharpen)
        case "sr-still": return yesNo(srStill)
        case "save-scale": return saveScale.text
        case "save-upscaler": return saveUpscaler.rawValue
        case "vibrance": return formatNumber(vibrance)
        case "vibrance-on": return yesNo(vibranceOn)
        case "auto-color": return yesNo(autoColor)
        case "auto-color-strength": return formatNumber(autoColorStrength)
        case "auto-color-filters":
            let names = AutoColorFilter.allCases.filter(autoColorFilters.contains).map(\.rawValue)
            return names.isEmpty ? "none" : names.joined(separator: ",")
        case "auto-color-vibrance-gain": return formatNumber(autoColorVibranceGain)
        case "auto-color-interval": return formatNumber(autoColorInterval)
        case "auto-color-threshold": return formatNumber(autoColorThreshold)
        case "auto-color-full": return formatNumber(autoColorFull)
        case "save-color": return yesNo(saveColor)
        case "ontop": return yesNo(ontop)
        case "stats-font-size": return String(statsFontSize)
        case "hold-speed": return formatNumber(holdSpeed)
        case "speed-step": return formatNumber(speedStep)
        case "keep-speed": return yesNo(keepSpeed)
        case "scrub-audio": return yesNo(scrubAudio)
        case "scrub-audio-length": return String(scrubAudioLengthMs)
        case "scrub-audio-pitch": return scrubAudioPitch.rawValue
        case "ab-loop": return abLoop.rawValue
        case "segment-advance": return segmentAdvance.rawValue
        case "key-layout": return keyLayout.rawValue
        case "app-icon": return appIcon
        default: return nil
        }
    }

    /// Writes only `keys` into the file at `url`, keeping everything else in it (Preferences).
    public func write(keys: [String], to url: URL = Config.fileURL) throws {
        // Only a missing file starts empty; any other read failure must not clobber the file.
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""
        let values = keys.compactMap { key in text(forKey: key).map { (key: key, value: $0) } }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ConfigText.setting(values, in: existing).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Parses config text. Lines with unknown keys or invalid values are ignored and reported.
    public static func parse(_ text: String) -> (Config, [String]) {
        var config = Config()
        var warnings: [String] = []
        for (number, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = stripComment(raw)
            guard !line.isEmpty else { continue }
            let location = "framescrub.conf:\(number + 1)"
            guard let equals = line.firstIndex(of: "=") else {
                warnings.append("\(location): expected key=value")
                continue
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if !config.set(key, value) {
                warnings.append("\(location): bad option '\(key)=\(value)'")
            }
        }
        return (config, warnings)
    }

    public static func load() -> (Config, [String]) {
        let url = directory.appendingPathComponent("framescrub.conf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (Config(), []) }
        return parse(text)
    }

    private mutating func set(_ key: String, _ value: String) -> Bool {
        func int(_ range: ClosedRange<Int>) -> Int? { Int(value).flatMap { range.contains($0) ? $0 : nil } }
        func double(_ range: ClosedRange<Double>) -> Double? { Double(value).flatMap { range.contains($0) ? $0 : nil } }
        func bool() -> Bool? {
            switch value.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        switch key {
        case "cache-size": guard let v = int(64...1_048_576) else { return false }; cacheSizeMiB = v
        case "read-cache": guard let v = int(0...4096) else { return false }; readCacheMiB = v
        case "scrub-px-per-frame": guard let v = double(0.5...500) else { return false }; scrub.pxPerFrame = v
        case "scrub-accel-from": guard let v = double(5...120) else { return false }; scrub.accelFrom = v
        case "scrub-accel-max": guard let v = double(30...2000) else { return false }; scrub.accelMax = v
        case "scrub-invert": guard let v = bool() else { return false }; scrub.invert = v
        case "scrub-accel": guard let v = bool() else { return false }; scrub.accelerate = v
        case "wheel-precision": guard let v = bool() else { return false }; wheelPrecision = v
        case "wheel-precision-mode": guard let v = WheelPrecisionMode(rawValue: value.lowercased()) else { return false }; scrub.precisionMode = v
        case "wheel-precision-frames": guard let v = double(0.5...6) else { return false }; scrub.precisionFramesPerNotch = v
        case "wheel-precision-time": guard let v = double(20...250) else { return false }; scrub.precisionMsPerNotch = v
        case "mouse-long-press": guard let v = int(150...2000) else { return false }; mouseLongPress = v
        case "mouse-haptics": guard let v = bool() else { return false }; mouseHaptics = v
        case "haptic-strength":
            if value.lowercased() == "keep" { hapticStrength = nil } else { guard let v = int(0...100) else { return false }; hapticStrength = v }
        case "haptic-strong-strength": guard let v = int(0...100) else { return false }; hapticStrongStrength = v
        case "mx-panel-force": guard let v = PanelForceSetting.parse(value) else { return false }; mxPanelForce = v
        case "mx-side-buttons": guard let v = SideButtonsMode(rawValue: value.lowercased()) else { return false }; mxSideButtons = v
        case _ where hapticEvent(forKey: key) != nil:
            guard let v = HapticChoice.parse(value) else { return false }
            haptics.choices[hapticEvent(forKey: key)!] = v
        case "frame-format": guard let v = ImageFormat(rawValue: value.lowercased()) else { return false }; frameFormat = v
        case "jpeg-quality": guard let v = int(1...100) else { return false }; jpegQuality = v
        case "heic-quality": guard let v = int(1...100) else { return false }; heicQuality = v
        case "frame-dir": guard !value.isEmpty else { return false }; frameDirectory = value
        case "frame-template": guard !value.isEmpty else { return false }; frameTemplate = value
        case "export-threads": guard let v = int(1...64) else { return false }; exportThreads = v
        case "volume": guard let v = double(0...100) else { return false }; volume = v
        case "scrub-fast-multiplier": guard let v = double(1...100) else { return false }; scrub.fastMultiplier = v
        case "seek-mode": guard let v = SeekMode(rawValue: value.lowercased()) else { return false }; seekMode = v
        case "scene-threshold": guard let v = double(0...255) else { return false }; sceneThreshold = v
        case "scene-lookahead": guard let v = int(0...1000) else { return false }; sceneLookahead = v
        case "scene-check-time": guard let v = double(0...30) else { return false }; sceneCheckTime = v
        case "scene-search-time": guard let v = double(0.5...120) else { return false }; sceneSearchTime = v
        case "hwdec": guard let v = HardwareDecoding(rawValue: value.lowercased()) else { return false }; hwdec = v
        case "network-mode": guard let v = NetworkMode(rawValue: value.lowercased()) else { return false }; networkMode = v
        case "resume-playback": guard let v = bool() else { return false }; resumePlayback = v
        case "playlist-autoadvance": guard let v = bool() else { return false }; playlistAutoadvance = v
        case "autoplay": guard let v = bool() else { return false }; autoplay = v
        case "activate-on-open": guard let v = bool() else { return false }; activateOnOpen = v
        case "playlist-sort": guard let v = PlaylistSort(rawValue: value.lowercased()) else { return false }; playlistSort = v
        case "playlist-font-size": guard let v = int(9...32) else { return false }; playlistFontSize = v
        case "home-card-size": guard let v = double(60...480) else { return false }; homeCardSize = v
        case "recent-count": guard let v = int(1...200) else { return false }; recentCount = v
        case "home-sidebar": guard let v = bool() else { return false }; homeSidebar = v
        case "single-instance": guard let v = bool() else { return false }; singleInstance = v
        case "home-tab": guard let v = HomeTab(rawValue: value.lowercased()) else { return false }; homeTab = v
        case "stash-url": stashURL = value
        case "stash-api-key": stashAPIKey = value
        case "stash-path-map": stashPathMap = value
        case "stash-stream": guard let v = StashStreaming(rawValue: value.lowercased()) else { return false }; stashStream = v
        case "plugin-open-allowed": pluginOpenAllowed = value
        case "plugin":
            guard let entry = PluginEntry(line: value) else { return false }
            if !plugins.contains(where: { $0.name == entry.name }) { plugins.append(entry) }
        case _ where SlotEdge.allCases.contains(where: { $0.key == key }):
            let edge = SlotEdge.allCases.first { $0.key == key }!
            guard let setting = SlotSetting(text: value) else { return false }
            slots[edge] = setting.clamped(for: edge)
        case "slot-reveal-distance": guard let v = int(2...60) else { return false }; slotRevealDistance = v
        case "mouse-profile": guard let v = MouseProfile(rawValue: value.lowercased()) else { return false }; mouseProfile = v
        case "preview": guard let v = bool() else { return false }; preview = v
        case "preview-width": guard let v = double(80...640) else { return false }; previewWidth = v
        case "export-mode": guard let v = ExportMode(rawValue: value.lowercased()) else { return false }; exportMode = v
        case "export-every": guard let v = int(2...10_000) else { return false }; exportEvery = v
        case "export-fps": guard let v = double(0.01...240) else { return false }; exportFPS = v
        case "export-scale": guard let v = OutputSize(text: value) else { return false }; exportScale = v
        case "export-sharp": guard let v = bool() else { return false }; exportSharp = v
        case "export-sharp-threshold": guard let v = int(1...100) else { return false }; exportSharpThreshold = v
        case "export-sharp-neighbours": guard let v = int(3...31), v % 2 == 1 else { return false }; exportSharpNeighbours = v
        case "export-skip-blurry": guard let v = bool() else { return false }; exportSkipBlurry = v
        case "export-skip-duplicates": guard let v = bool() else { return false }; exportSkipDuplicates = v
        case "export-duplicate-change": guard let v = int(1...100) else { return false }; exportDuplicateChange = v
        case "clip-template": guard !value.isEmpty else { return false }; clipTemplate = value
        case "clip-read-limit": guard let v = int(0...1000) else { return false }; clipReadLimitMB = v
        case "clip-mode": guard let v = ClipMode(rawValue: value.lowercased()) else { return false }; clipMode = v
        case "clip-confirm": guard let v = bool() else { return false }; clipConfirm = v
        case "scale": guard let v = ScaleMode(rawValue: value.lowercased()) else { return false }; scaleMode = v
        case "sharpen": guard let v = double(0...1) else { return false }; sharpen = v
        case "sr-still": guard let v = bool() else { return false }; srStill = v
        case "save-scale": guard let v = OutputSize(text: value) else { return false }; saveScale = v
        case "save-upscaler": guard let v = Upscaler(rawValue: value.lowercased()) else { return false }; saveUpscaler = v
        case "vibrance": guard let v = double(0...1) else { return false }; vibrance = v
        case "vibrance-on": guard let v = bool() else { return false }; vibranceOn = v
        case "auto-color": guard let v = bool() else { return false }; autoColor = v
        case "auto-color-strength": guard let v = double(0...1) else { return false }; autoColorStrength = v
        case "auto-color-filters":
            let names = value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            if names == ["none"] { autoColorFilters = []; break }
            let filters = names.compactMap(AutoColorFilter.init(rawValue:))
            guard filters.count == names.count else { return false }
            autoColorFilters = Set(filters)
        case "auto-color-vibrance-gain": guard let v = double(1...8) else { return false }; autoColorVibranceGain = v
        case "auto-color-interval": guard let v = double(0...600) else { return false }; autoColorInterval = v
        case "auto-color-threshold": guard let v = double(0...50) else { return false }; autoColorThreshold = v
        case "auto-color-full": guard let v = double(0...50) else { return false }; autoColorFull = v
        case "save-color": guard let v = bool() else { return false }; saveColor = v
        case "ontop": guard let v = bool() else { return false }; ontop = v
        case "stats-font-size": guard let v = int(8...40) else { return false }; statsFontSize = v
        case "hold-speed": guard let v = double(0.1...16) else { return false }; holdSpeed = v
        case "speed-step": guard let v = double(0.01...4), v > 0 else { return false }; speedStep = v
        case "keep-speed": guard let v = bool() else { return false }; keepSpeed = v
        case "scrub-audio": guard let v = bool() else { return false }; scrubAudio = v
        case "scrub-audio-length": guard let v = int(20...500) else { return false }; scrubAudioLengthMs = v
        case "scrub-audio-pitch": guard let v = ScrubPitch(rawValue: value.lowercased()) else { return false }; scrubAudioPitch = v
        case "ab-loop": guard let v = ABLoopMode(rawValue: value.lowercased()) else { return false }; abLoop = v
        case "segment-advance": guard let v = SegmentAdvance(rawValue: value.lowercased()) else { return false }; segmentAdvance = v
        case "key-layout": guard let v = KeyLayout(rawValue: value.lowercased()) else { return false }; keyLayout = v
        case "app-icon": guard let v = AppIcon.normalized(value) else { return false }; appIcon = v
        default: return false
        }
        return true
    }
}

extension Config {
    /// This config with stored colour `values` (key → text, as framescrub.conf spells them) on top. Only
    /// `ColorLayers.keys` are taken. `rejected` lists `key=value` for every entry that is no colour key or whose value
    /// `set` refuses, sorted by key; those are skipped (the caller logs them once).
    public func applying(_ overrides: [String: String]) -> (config: Config, rejected: [String]) {
        let applied = applyingColors(overrides)
        return (applied.config, applied.rejected)
    }

    /// `applying`, also saying whether any colour key was taken.
    func applyingColors(_ overrides: [String: String]) -> (config: Config, rejected: [String], accepted: Bool) {
        var config = self
        var rejected: [String] = []
        var accepted = false
        for key in overrides.keys.sorted() {
            let value = overrides[key]!
            if ColorLayers.keys.contains(key), config.set(key, value) { accepted = true } else { rejected.append("\(key)=\(value)") }
        }
        return (config, rejected, accepted)
    }
}
