import FrameScrubCore
import SwiftUI

struct ExportSheetView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case all = "All frames", every = "Every N-th frame", perSecond = "N frames per second"
        var id: String { rawValue }
    }

    let rangeText: String                                   // "frames 120–480"
    let source: CGSize                                      // upright source size in pixels
    let screen: CGSize?
    let hdr: Bool
    let upscaler: Upscaler
    let count: (ExportSelection) -> Int?                    // files an export with this selection would write
    let onStart: (ExportSelection, OutputSize, Filters) -> Void
    let onCancel: () -> Void

    /// Which frames of each window are saved (`export-sharp`, `export-skip-blurry`, `export-skip-duplicates`).
    struct Filters {
        var sharpest: Bool
        var skipBlurry: Bool
        /// Percent of the neighbours' median sharpness.
        var blurryThreshold: Int
        var skipDuplicates: Bool
        /// Percent of the picture changed since the last saved frame.
        var duplicateChange: Int
    }

    /// The editable choices. An observable object rather than `@State`: the command-line toolchain has no SwiftUI macro plugin.
    final class Choices: ObservableObject {
        @Published var mode: Mode
        /// What is typed in the fields: read at the moment of use, so Export never sees a value that was not committed yet.
        @Published var everyText: String
        @Published var fpsText: String
        private var lastEvery: Int
        private var lastFPS: Double
        @Published var size: OutputSize
        @Published var sharpest: Bool
        @Published var skipBlurry: Bool
        @Published var thresholdText: String
        private var lastThreshold: Int
        @Published var skipDuplicates: Bool
        @Published var changeText: String
        private var lastChange: Int
        init(mode: Mode, every: Int, fps: Double, size: OutputSize, filters: Filters) {
            self.mode = mode; self.size = size
            lastEvery = every; lastFPS = fps
            everyText = String(every); fpsText = fps.formatted(.number.grouping(.never))
            sharpest = filters.sharpest; skipBlurry = filters.skipBlurry
            lastThreshold = filters.blurryThreshold; thresholdText = String(filters.blurryThreshold)
            skipDuplicates = filters.skipDuplicates
            lastChange = filters.duplicateChange; changeText = String(filters.duplicateChange)
        }
        /// The typed value; the last valid one while the text does not parse.
        var every: Int {
            if let n = Int(everyText.trimmingCharacters(in: .whitespaces)) { lastEvery = n }
            return lastEvery
        }
        var fps: Double {
            if let f = Double(fpsText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), f.isFinite { lastFPS = f }
            return lastFPS
        }
        /// Percent, 1…100; the last valid one while the text does not parse.
        var threshold: Int {
            if let n = Int(thresholdText.trimmingCharacters(in: .whitespaces)), (1...100).contains(n) { lastThreshold = n }
            return lastThreshold
        }
        var change: Int {
            if let n = Int(changeText.trimmingCharacters(in: .whitespaces)), (1...100).contains(n) { lastChange = n }
            return lastChange
        }
        var filters: Filters {
            Filters(sharpest: sharpest, skipBlurry: skipBlurry, blurryThreshold: threshold,
                    skipDuplicates: skipDuplicates, duplicateChange: change)
        }
    }

    @StateObject private var choices: Choices

    init(rangeText: String, source: CGSize, screen: CGSize?, hdr: Bool, upscaler: Upscaler,
         count: @escaping (ExportSelection) -> Int?,
         onStart: @escaping (ExportSelection, OutputSize, Filters) -> Void,
         onCancel: @escaping () -> Void,
         mode: Mode, every: Int, fps: Double, size: OutputSize, filters: Filters) {
        self.rangeText = rangeText; self.source = source; self.screen = screen; self.hdr = hdr
        self.upscaler = upscaler; self.count = count; self.onStart = onStart; self.onCancel = onCancel
        _choices = StateObject(wrappedValue: Choices(mode: mode, every: every, fps: fps, size: size, filters: filters))
    }

    private var selection: ExportSelection {
        switch choices.mode {
        case .all: return .all
        case .every: return .every(max(2, choices.every))
        case .perSecond: return .perSecond(max(0.01, choices.fps))
        }
    }

    private var files: Int { count(selection) ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export range").font(.headline)
            Picker("Frames", selection: $choices.mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch choices.mode {
            case .all: EmptyView()
            case .every:
                HStack { Text("Every"); TextField("N", text: $choices.everyText).frame(width: 70); Text("frames") }
            case .perSecond:
                HStack { TextField("N", text: $choices.fpsText).frame(width: 70); Text("frames per second") }
            }
            Toggle("Sharpest frame of each window", isOn: $choices.sharpest)
                .disabled(choices.mode == .all)   // a window of one frame
            HStack {
                Toggle("Skip blurry: below", isOn: $choices.skipBlurry)
                TextField("80", text: $choices.thresholdText).frame(width: 50).disabled(!choices.skipBlurry)
                Text("% of the neighbours' sharpness")
            }
            HStack {
                Toggle("Skip near-duplicates: save when", isOn: $choices.skipDuplicates)
                TextField("\(DuplicateFilter.defaultChange)", text: $choices.changeText).frame(width: 50).disabled(!choices.skipDuplicates)
                Text("% of the picture changed")
            }
            HStack { Text("Size"); OutputSizeField(selection: $choices.size) }
            VStack(alignment: .leading, spacing: 2) {
                Text(choices.skipBlurry || choices.skipDuplicates
                     ? "Will save up to \(files) files (\(rangeText))" : "Will save \(files) files (\(rangeText))")
                if let seconds = ExportEstimate.mlSeconds(frames: files, source: source, output: choices.size, screen: screen,
                                                          upscaler: upscaler, hdr: hdr) {
                    Text("Neural-network upscaling: \(ExportEstimate.text(seconds: seconds))")
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Export") { onStart(selection, choices.size, choices.filters) }.keyboardShortcut(.defaultAction).disabled(files == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
