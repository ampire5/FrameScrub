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
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "Export frames", detail: rangeText)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Frame sampling", selection: $choices.mode) {
                    Text("All frames").tag(Mode.all)
                    Text("Every N frames").tag(Mode.every)
                    Text("Frames per second").tag(Mode.perSecond)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                switch choices.mode {
                case .all: EmptyView()
                case .every:
                    LabeledContent("Frame interval") {
                        numberField("Frames", text: $choices.everyText)
                    }
                case .perSecond:
                    LabeledContent("Frames per second") {
                        numberField("Frames per second", text: $choices.fpsText)
                    }
                }
                Toggle("Keep the sharpest frame per interval", isOn: $choices.sharpest)
                    .disabled(choices.mode == .all)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                    GridRow {
                        Toggle("Skip blurry frames", isOn: $choices.skipBlurry)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        numberField("Sharpness threshold", text: $choices.thresholdText)
                            .disabled(!choices.skipBlurry)
                        Text("% of nearby sharpness").foregroundStyle(.secondary)
                    }
                    GridRow {
                        Toggle("Skip near duplicates", isOn: $choices.skipDuplicates)
                        numberField("Minimum picture change", text: $choices.changeText)
                            .disabled(!choices.skipDuplicates)
                        Text("% minimum change").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Output size") { OutputSizeField(selection: $choices.size) }
            }
            Text(choices.skipBlurry || choices.skipDuplicates
                 ? "Up to \(files) image files" : "\(files) image files")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            SheetActions(onCancel: onCancel) {
                Button("Export") { onStart(selection, choices.size, choices.filters) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(files == 0)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField("", text: text)
            .accessibilityLabel(label)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: 56)
    }
}
