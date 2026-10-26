import FrameScrubCore
import HomeScreenKit
import SwiftUI

/// A text field that keeps its own draft, so it can be emptied while typing; a non-empty draft is committed
/// at once, and the draft follows changes made elsewhere.
private struct DraftField: View {
    let title: String
    @Binding var value: String
    @StateObject private var draft: Draft
    @FocusState private var focused: Bool

    private final class Draft: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    init(_ title: String, value: Binding<String>) {
        self.title = title
        _value = value
        _draft = StateObject(wrappedValue: Draft(value.wrappedValue))
    }

    var body: some View {
        TextField("", text: Binding(get: { draft.text }, set: { text in
            draft.text = text
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed != value { value = trimmed }
        }))
        .onSubmit { draft.text = value }
        .onChange(of: focused) { _, isFocused in if !isFocused, draft.text.trimmingCharacters(in: .whitespaces).isEmpty { draft.text = value } }
        .focused($focused)
        .onChange(of: value) { _, new in
            if !draft.text.trimmingCharacters(in: .whitespaces).isEmpty, draft.text.trimmingCharacters(in: .whitespaces) != new { draft.text = new }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)   // a grouped form aligns its trailing column to the right
        .frame(width: 320)
        .help(value)
    }
}

/// "Title ……… value [stepper]": the value sits next to its control, not inside the title.
private struct StepperRow: View {
    let title: String
    var note: String? = nil
    let value: String
    @Binding var number: Int
    let range: ClosedRange<Int>
    var step = 1

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(value).monospacedDigit()
                Stepper("", value: $number, in: range, step: step).labelsHidden()
            }
        } label: {
            Text(title)
            if let note { Text(note) }
        }
    }
}

/// "Title ……… [slider] value", the value in a fixed column so the sliders of a section line up.
private struct SliderRow: View {
    let title: String
    let value: String
    @Binding var number: Double
    let range: ClosedRange<Double>
    var step: Double? = nil

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                if let step {
                    Slider(value: $number, in: range, step: step).labelsHidden()
                } else {
                    Slider(value: $number, in: range).labelsHidden()
                }
                Text(value).monospacedDigit().foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            }
            .frame(width: 250)
        }
    }
}

/// One tab of the settings window. Each lives in its own hosting controller (`PreferencesWindowController`):
/// a SwiftUI `TabView` rebuilt and laid out the heavy forms on every switch, which was a visible lag on slower Macs.
struct PreferencesView: View {
    enum Tab: CaseIterable, Hashable {
        case general, scrolling, saving, display, mouse, stash
        var title: String {
            switch self {
            case .general: return "General"
            case .scrolling: return "Scrolling"
            case .saving: return "Saving"
            case .display: return "Display"
            case .mouse: return "Mouse & Trackpad"
            case .stash: return "Stash"
            }
        }
    }

    @ObservedObject var feed: PreferencesTabFeed
    var tab: Tab
    var mouseTab: AnyView? = nil
    private var model: PreferencesModel { feed.model }
    /// The wheel mode of the player (SmartShift's choice, remembered); missing means free spin.
    @AppStorage(PlayerWindowController.wheelFreeSpinKey) private var wheelFreeSpin = true

    var body: some View {
        VStack(spacing: 0) {
            switch tab {
            case .general: general
            case .scrolling: scrolling
            case .saving: saving
            case .display: display
            case .mouse: mouseTab
            case .stash: StashPreferencesView(feed: feed)
            }
            if let message = model.errorMessage {
                Text(message).foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true).padding(8)
            }
        }
        .frame(width: PreferencesTabsController.contentSize.width, height: PreferencesTabsController.contentSize.height)
    }

    /// `scrub-audio-pitch` as an on/off toggle: on is `natural`.
    private var naturalScrubPitch: Binding<Bool> {
        let pitch = model.binding(\.scrubAudioPitch, ["scrub-audio-pitch"])
        return Binding(get: { pitch.wrappedValue == .natural }, set: { pitch.wrappedValue = $0 ? .natural : .tape })
    }

    /// `scrub-audio-length` is whole milliseconds; the slider works in Double.
    private var scrubAudioLength: Binding<Double> {
        let milliseconds = model.binding(\.scrubAudioLengthMs, ["scrub-audio-length"])
        return Binding(get: { Double(milliseconds.wrappedValue) }, set: { milliseconds.wrappedValue = Int($0.rounded()) })
    }

    /// The threshold is a number in the file, whole steps in the stepper.
    private var sceneThreshold: Binding<Int> {
        let inner = model.binding(\.sceneThreshold, ["scene-threshold"])
        return Binding(get: { Int(inner.wrappedValue.rounded()) }, set: { inner.wrappedValue = Double($0) })
    }

    /// Read once: the bundle does not change while the app runs.
    private static let buildLine = BuildInfo.line(of: .current)

    private var general: some View {
        Form {
            Section("Playback") {
                SliderRow(title: "Volume", value: "\(Int(model.config.volume)) %",
                          number: model.binding(\.volume, ["volume"]), range: 0...100, step: 1)
                SliderRow(title: "Speed while the hold key is held", value: String(format: "%g×", model.config.holdSpeed),
                          number: model.binding(\.holdSpeed, ["hold-speed"], decimals: 2), range: 1.25...8, step: 0.25)
                SliderRow(title: "Speed step ([ ])", value: String(format: "%g×", model.config.speedStep),
                          number: model.binding(\.speedStep, ["speed-step"], decimals: 2), range: 0.05...1, step: 0.05)
                Toggle("Keep the speed for the next video", isOn: model.binding(\.keepSpeed, ["keep-speed"]))
                Toggle("Sound on every frame change in pause (⌥m)", isOn: model.binding(\.scrubAudio, ["scrub-audio"]))
                Toggle("Natural pitch while scrubbing (⇧⌥m)", isOn: naturalScrubPitch)
                SliderRow(title: "Scrub audio length", value: "\(model.config.scrubAudioLengthMs) ms",
                          number: scrubAudioLength, range: 20...500, step: 10)
                Picker("At the end of the A-B range", selection: model.binding(\.abLoop, ["ab-loop"])) {
                    ForEach(ABLoopMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("Relative seeks and seek bar", selection: model.binding(\.seekMode, ["seek-mode"])) {
                    Text("Nearest keyframe").tag(SeekMode.keyframe)
                    Text("Exact frame").tag(SeekMode.exact)
                }
                StepperRow(title: "Scene cut threshold", value: "\(sceneThreshold.wrappedValue)", number: sceneThreshold, range: 1...100)
                StepperRow(title: "Scenes searched ahead (keyframes)", value: "\(model.config.sceneLookahead)",
                           number: model.binding(\.sceneLookahead, ["scene-lookahead"]), range: 0...200, step: 10)
                SliderRow(title: "Scene search: frame-by-frame checks per press",
                          value: model.config.sceneCheckTime == 0 ? "off" : String(format: "%g s", model.config.sceneCheckTime),
                          number: model.binding(\.sceneCheckTime, ["scene-check-time"], decimals: 1), range: 0...5, step: 0.5)
                SliderRow(title: "Scene search: longest wait per press", value: String(format: "%g s", model.config.sceneSearchTime),
                          number: model.binding(\.sceneSearchTime, ["scene-search-time"], decimals: 1), range: 1...30, step: 1)
                Picker("Video decoding", selection: model.binding(\.hwdec, ["hwdec"])) {
                    Text("Auto (VideoToolbox)").tag(HardwareDecoding.auto)
                    Text("Hardware (VideoToolbox)").tag(HardwareDecoding.yes)
                    Text("Software").tag(HardwareDecoding.no)
                }
                Picker("Network volumes", selection: model.binding(\.networkMode, ["network-mode"])) {
                    Text("Read gently (automatic)").tag(NetworkMode.auto)
                    Text("Always read gently").tag(NetworkMode.yes)
                    Text("Never").tag(NetworkMode.no)
                }
                Toggle("Resume where I left off", isOn: model.binding(\.resumePlayback, ["resume-playback"]))
                Toggle("Play the next video in the folder at the end", isOn: model.binding(\.playlistAutoadvance, ["playlist-autoadvance"]))
                Toggle("Start playing when a file opens", isOn: model.binding(\.autoplay, ["autoplay"]))
                Toggle("Bring FrameScrub to the front when a file is opened from Finder", isOn: model.binding(\.activateOnOpen, ["activate-on-open"]))
                Picker("Folder order", selection: model.binding(\.playlistSort, ["playlist-sort"])) {
                    ForEach(PlaylistSort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Section("Memory") {
                StepperRow(title: "Frame cache", value: "\(model.config.cacheSizeMiB) MiB",
                           number: model.binding(\.cacheSizeMiB, ["cache-size"]), range: 64...1_048_576, step: 256)
                StepperRow(title: "Read cache", note: "Applies to the next file",
                           value: model.config.readCacheMiB == 0 ? "Off" : "\(model.config.readCacheMiB) MiB",
                           number: model.binding(\.readCacheMiB, ["read-cache"]), range: 0...4096, step: 64)
            }
            Section("App") {
                Picker("Keyboard layout", selection: model.binding(\.keyLayout, ["key-layout"])) {
                    ForEach(KeyLayout.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: model.binding(\.singleInstance, ["single-instance"])) {
                    Text("Only one running copy")
                    Text("Applies at the next launch")
                }
                StepperRow(title: "Playlist text size (F8)", value: "\(model.config.playlistFontSize) pt",
                           number: model.binding(\.playlistFontSize, ["playlist-font-size"]), range: 9...32)
                StepperRow(title: "Side slots come within", note: "How near the window's left or right edge the pointer brings a hidden slot",
                           value: "\(model.config.slotRevealDistance) pt",
                           number: model.binding(\.slotRevealDistance, ["slot-reveal-distance"]), range: 2...60, step: 2)
                StepperRow(title: "Stats text size (i)", value: "\(model.config.statsFontSize) pt",
                           number: model.binding(\.statsFontSize, ["stats-font-size"]), range: 8...40)
                SliderRow(title: "Start screen card size (largest)", value: "\(Int(model.config.startCardSize)) pt",
                          number: model.binding(\.startCardSize, ["start-card-size"], decimals: 0), range: 140...800, step: 20)
                Picker("Start screen layout", selection: model.binding(\.homeLayout, ["home-layout"])) {
                    Text("Fit (shrink, then scroll)").tag(HomeLayoutMode.fit)
                    Text("Scroll").tag(HomeLayoutMode.scroll)
                    Text("Fixed (no scrolling)").tag(HomeLayoutMode.fixed)
                }
            }
            Section("Build") {
                // Which build this is, to quote when something is wrong (selectable, and a button copies it).
                HStack {
                    Text(Self.buildLine).textSelection(.enabled).font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.buildLine, forType: .string)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `haptic-strength`: nil is "keep" (the mouse's own setting stays).
    private var hapticStrengthKept: Binding<Bool> {
        let strength = model.binding(\.hapticStrength, ["haptic-strength"])
        return Binding(get: { strength.wrappedValue == nil }, set: { keep in strength.wrappedValue = keep ? nil : 35 })
    }

    private var hapticStrengthValue: Binding<Double> {
        let strength = model.binding(\.hapticStrength, ["haptic-strength"])
        return Binding(get: { Double(strength.wrappedValue ?? 0) }, set: { strength.wrappedValue = Int($0.rounded()) })
    }

    private enum PanelForceChoice: Hashable { case keep, factory, custom }

    private var panelForceChoice: Binding<PanelForceChoice> {
        let force = model.binding(\.mxPanelForce, ["mx-panel-force"])
        return Binding(get: {
            switch force.wrappedValue {
            case .keep: return .keep
            case .factoryDefault: return .factory
            case .percent: return .custom
            }
        }, set: { choice in
            switch choice {
            case .keep: force.wrappedValue = .keep
            case .factory: force.wrappedValue = .factoryDefault
            case .custom: force.wrappedValue = .percent(50)
            }
        })
    }

    private var panelForcePercent: Binding<Double> {
        let force = model.binding(\.mxPanelForce, ["mx-panel-force"])
        return Binding(get: {
            if case .percent(let p) = force.wrappedValue { return Double(p) }
            return 50
        }, set: { force.wrappedValue = .percent(Int($0.rounded())) })
    }

    private var sideButtonsCaption: String {
        switch model.config.mxSideButtons {
        case .watch: return "Watch: listen to the mouse, so Mac Mouse Fix and the system keep Back / Forward."
        case .take: return "Take: Back / Forward are FrameScrub's alone while it is in front."
        case .system: return "System only: no HID++, the buttons come through macOS as usual."
        }
    }

    private var scrolling: some View {
        Form {
            Section("Trackpad and mouse wheel scrubbing") {
                Toggle("Accelerate: faster movement takes bigger steps", isOn: model.binding(\.scrub.accelerate, ["scrub-accel"]))
                SliderRow(title: "Points per frame", value: String(format: "%.1f", model.config.scrub.pxPerFrame),
                          number: model.binding(\.scrub.pxPerFrame, ["scrub-px-per-frame"], decimals: 1), range: 0.5...100)
                SliderRow(title: "Acceleration starts at", value: "\(Int(model.config.scrub.accelFrom)) fps",
                          number: model.binding(\.scrub.accelFrom, ["scrub-accel-from"], decimals: 0), range: 5...120)
                    .disabled(!model.config.scrub.accelerate)
                SliderRow(title: "Fastest accelerated scrub", value: "\(Int(model.config.scrub.accelMax)) fps",
                          number: model.binding(\.scrub.accelMax, ["scrub-accel-max"], decimals: 0), range: 30...2000)
                    .disabled(!model.config.scrub.accelerate)
                SliderRow(title: "Fast scrub", value: "×\(Int(model.config.scrub.fastMultiplier))",
                          number: model.binding(\.scrub.fastMultiplier, ["scrub-fast-multiplier"]), range: 1...100, step: 1)
                Toggle("Invert scrub direction", isOn: model.binding(\.scrub.invert, ["scrub-invert"]))
            }
            Section("Logitech mouse") {
                Toggle("Free spin and Precision Scroll in the player", isOn: model.binding(\.wheelPrecision, ["wheel-precision"]))
                Group {
                    Picker("Wheel in the player", selection: $wheelFreeSpin) {
                        Text("Free spin + Precision Scroll").tag(true)
                        Text("Ratchet").tag(false)
                    }
                    Picker("Precision Scroll speed", selection: model.binding(\.scrub.precisionMode, ["wheel-precision-mode"])) {
                        Text("Frames a notch").tag(WheelPrecisionMode.frames)
                        Text("Video time a notch (by fps)").tag(WheelPrecisionMode.fps)
                    }
                    if model.config.scrub.precisionMode == .frames {
                        SliderRow(title: "Frames a notch",
                                  value: String(format: "%.1f", model.config.scrub.precisionFramesPerNotch),
                                  number: model.binding(\.scrub.precisionFramesPerNotch, ["wheel-precision-frames"], decimals: 1),
                                  range: 0.5...6)
                    } else {
                        SliderRow(title: "Video time a notch", value: "\(Int(model.config.scrub.precisionMsPerNotch)) ms",
                                  number: model.binding(\.scrub.precisionMsPerNotch, ["wheel-precision-time"], decimals: 0),
                                  range: 20...250)
                    }
                }
                .disabled(!model.config.wheelPrecision)
                Toggle("Mouse haptics", isOn: model.binding(\.mouseHaptics, ["mouse-haptics"]))
                Toggle("Leave haptic strength as it is", isOn: hapticStrengthKept)
                SliderRow(title: "Haptic strength", value: model.config.hapticStrength.map(String.init) ?? "as is",
                          number: hapticStrengthValue, range: 0...100, step: 5)
                    .disabled(model.config.hapticStrength == nil)
                Picker("Panel force", selection: panelForceChoice) {
                    Text("Leave as it is").tag(PanelForceChoice.keep)
                    Text("Factory").tag(PanelForceChoice.factory)
                    Text("Custom").tag(PanelForceChoice.custom)
                }
                if case .percent(let percent) = model.config.mxPanelForce {
                    SliderRow(title: "Panel force", value: "\(percent)", number: panelForcePercent, range: 0...100, step: 5)
                }
                Picker("Back / forward", selection: model.binding(\.mxSideButtons, ["mx-side-buttons"])) {
                    Text("Watch").tag(SideButtonsMode.watch)
                    Text("Take").tag(SideButtonsMode.take)
                    Text("System only").tag(SideButtonsMode.system)
                }
                Text(sideButtonsCaption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var saving: some View {
        Form {
            Section("File") {
                Picker("Format", selection: model.binding(\.frameFormat, ["frame-format"])) {
                    Text("JPEG").tag(ImageFormat.jpeg); Text("PNG").tag(ImageFormat.png)
                    Text("HEIC").tag(ImageFormat.heic); Text("TIFF").tag(ImageFormat.tiff)
                }
                StepperRow(title: "JPEG quality", value: "\(model.config.jpegQuality)",
                           number: model.binding(\.jpegQuality, ["jpeg-quality"]), range: 1...100)
                StepperRow(title: "HEIC quality", value: "\(model.config.heicQuality)",
                           number: model.binding(\.heicQuality, ["heic-quality"]), range: 1...100)
                LabeledContent("Folder") { DraftField("Folder", value: model.binding(\.frameDirectory, ["frame-dir"])) }
                LabeledContent("File name") { DraftField("File name", value: model.binding(\.frameTemplate, ["frame-template"])) }
            }
            Section("Size") {
                LabeledContent("Saved and copied frames") { OutputSizeField(selection: model.binding(\.saveScale, ["save-scale"])) }
                LabeledContent("Exported frames (A–B)") { OutputSizeField(selection: model.binding(\.exportScale, ["export-scale"])) }
                Picker("Enlarge with", selection: model.binding(\.saveUpscaler, ["save-upscaler"])) {
                    Text("Apple neural network (when possible)").tag(Upscaler.ml)
                    Text("Lanczos").tag(Upscaler.lanczos)
                }
            }
            Section("Clips") {
                LabeledContent("File name") { DraftField("File name", value: model.binding(\.clipTemplate, ["clip-template"])) }
                Picker("Marks are saved as", selection: model.binding(\.clipMode, ["clip-mode"])) {
                    ForEach(ClipMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Ask how to save when there are several marks", isOn: model.binding(\.clipConfirm, ["clip-confirm"]))
                StepperRow(title: "Read speed limit",
                           value: model.config.clipReadLimitMB == 0 ? "No limit" : "\(model.config.clipReadLimitMB) MB/s",
                           number: model.binding(\.clipReadLimitMB, ["clip-read-limit"]), range: 0...1000, step: 10)
            }
            Section("Range export") {
                StepperRow(title: "Threads", value: "\(model.config.exportThreads)",
                           number: model.binding(\.exportThreads, ["export-threads"]), range: 1...64)
            }
        }
        .formStyle(.grouped)
    }

    /// One part of `auto-color-filters` as a checkbox.
    private func autoFilter(_ filter: AutoColorFilter) -> Binding<Bool> {
        let filters = model.binding(\.autoColorFilters, ["auto-color-filters"])
        return Binding(get: { filters.wrappedValue.contains(filter) }, set: { on in
            var value = filters.wrappedValue
            if on { value.insert(filter) } else { value.remove(filter) }
            filters.wrappedValue = value
        })
    }

    private var display: some View {
        Form {
            Section("Picture") {
                Picker("Scaling on screen", selection: model.binding(\.scaleMode, ["scale"])) {
                    Text("Automatic").tag(ScaleMode.auto); Text("MetalFX").tag(ScaleMode.metalfx)
                    Text("Lanczos").tag(ScaleMode.lanczos); Text("Bilinear").tag(ScaleMode.bilinear)
                }
                SliderRow(title: "Sharpening after enlarging", value: String(format: "%.2f", model.config.sharpen),
                          number: model.binding(\.sharpen, ["sharpen"], decimals: 2), range: 0...1)
                Toggle("Redraw a paused frame with the neural network", isOn: model.binding(\.srStill, ["sr-still"]))
            }
            Section("Colour") {
                Text("Defaults; a file or folder can override them (c, v, ⌥C, ⇧C)").font(.caption).foregroundStyle(.secondary)
                Toggle("Vibrance", isOn: model.binding(\.vibranceOn, ["vibrance-on"]))
                SliderRow(title: "Vibrance strength", value: String(format: "%.2f", model.config.vibrance),
                          number: model.binding(\.vibrance, ["vibrance"], decimals: 2), range: 0...1)
                Toggle("Auto colour, for scenes that need it", isOn: model.binding(\.autoColor, ["auto-color"]))
                SliderRow(title: "Correct scenes from",
                          value: model.config.autoColorThreshold == 0 ? "always" : "Δ \(Int(model.config.autoColorThreshold))",
                          number: model.binding(\.autoColorThreshold, ["auto-color-threshold"]), range: 0...20, step: 1)
                SliderRow(title: "Full strength from",
                          value: model.config.autoColorFull <= model.config.autoColorThreshold ? "at once" : "Δ \(Int(model.config.autoColorFull))",
                          number: model.binding(\.autoColorFull, ["auto-color-full"]), range: 0...30, step: 1)
                SliderRow(title: "Auto colour strength", value: String(format: "%.2f", model.config.autoColorStrength),
                          number: model.binding(\.autoColorStrength, ["auto-color-strength"], decimals: 2), range: 0...1)
                SliderRow(title: "Recompute auto colour every",
                          value: model.config.autoColorInterval == 0 ? "only c" : "\(Int(model.config.autoColorInterval)) s",
                          number: model.binding(\.autoColorInterval, ["auto-color-interval"]), range: 0...60, step: 1)
                Toggle("Auto colour: tone curve (contrast)", isOn: autoFilter(.curve))
                Toggle("Auto colour: shadows and highlights", isOn: autoFilter(.shadows))
                Toggle("Auto colour: vibrance", isOn: autoFilter(.vibrance))
                SliderRow(title: "Auto vibrance gain", value: String(format: "×%.1f", model.config.autoColorVibranceGain),
                          number: model.binding(\.autoColorVibranceGain, ["auto-color-vibrance-gain"], decimals: 1), range: 1...8)
                Toggle("Apply to saved and copied frames", isOn: model.binding(\.saveColor, ["save-color"]))
            }
            Section("Seek bar preview") {
                Toggle("Show a picture above the seek bar", isOn: model.binding(\.preview, ["preview"]))
                SliderRow(title: "Picture width", value: "\(Int(model.config.previewWidth)) pt",
                          number: model.binding(\.previewWidth, ["preview-width"]), range: 80...640, step: 20)
                    .disabled(!model.config.preview)
            }
        }
        .formStyle(.grouped)
    }
}
