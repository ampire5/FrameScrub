import FrameScrubCore
import SwiftUI

struct ExportSheetView: View {
    enum Mode: Hashable { case all, every, perSecond }

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
        @Published var size: OutputSize
        @Published var pixelsText: String
        @Published var sharpest: Bool
        @Published var skipBlurry: Bool
        @Published var thresholdText: String
        private let savedThreshold: Int
        @Published var skipDuplicates: Bool
        @Published var changeText: String
        private let savedChange: Int
        init(mode: Mode, every: Int, fps: Double, size: OutputSize, filters: Filters) {
            self.mode = mode; self.size = size
            everyText = String(every); fpsText = fps.formatted(.number.grouping(.never))
            switch size {
            case let .width(n), let .height(n): pixelsText = String(n)
            default: pixelsText = "3840"
            }
            sharpest = filters.sharpest; skipBlurry = filters.skipBlurry
            savedThreshold = filters.blurryThreshold; thresholdText = String(filters.blurryThreshold)
            skipDuplicates = filters.skipDuplicates
            savedChange = filters.duplicateChange; changeText = String(filters.duplicateChange)
        }
        var every: Int? { integer(everyText, in: 2...10_000) }
        var fps: Double? {
            let text = fpsText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(text), (0.01...240).contains(value) else { return nil }
            return value
        }
        var threshold: Int? { integer(thresholdText, in: 1...100) }
        var change: Int? { integer(changeText, in: 1...100) }
        var hasValidSize: Bool {
            switch size {
            case .width, .height: OutputSizeField.parsePixels(pixelsText) != nil
            default: true
            }
        }

        private func integer(_ text: String, in range: ClosedRange<Int>) -> Int? {
            guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else { return nil }
            return value
        }
        var filters: Filters? {
            guard let threshold = skipBlurry ? threshold : threshold ?? savedThreshold,
                  let change = skipDuplicates ? change : change ?? savedChange else { return nil }
            return Filters(sharpest: sharpest, skipBlurry: skipBlurry, blurryThreshold: threshold,
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

    private var selection: ExportSelection? {
        switch choices.mode {
        case .all: return .all
        case .every: return choices.every.map { .every($0) }
        case .perSecond: return choices.fps.map { .perSecond($0) }
        }
    }

    private var validationMessage: String? {
        if choices.mode == .every, choices.every == nil { return "Enter a whole frame interval from 2 to 10,000." }
        if choices.mode == .perSecond, choices.fps == nil { return "Enter a frame rate from 0.01 to 240 fps." }
        if choices.skipBlurry, choices.threshold == nil { return "Enter a sharpness threshold from 1 to 100%." }
        if choices.skipDuplicates, choices.change == nil { return "Enter a minimum picture change from 1 to 100%." }
        if !choices.hasValidSize {
            let limits = OutputSize.sideRange
            return "Enter an output size from \(limits.lowerBound.formatted()) to \(limits.upperBound.formatted()) px."
        }
        return nil
    }

    var body: some View {
        let message = validationMessage
        let files = message == nil ? selection.flatMap(count) : nil
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "Export frames", detail: rangeText)
            VStack(alignment: .leading, spacing: 8) {
                Picker("Frame sampling", selection: $choices.mode) {
                    Text("All frames").tag(Mode.all)
                    Text("Frame interval").tag(Mode.every)
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
                LabeledContent("Output size") { OutputSizeField(selection: $choices.size, pixelsText: $choices.pixelsText) }
            }
            Text(message ?? estimate(files))
                .font(.callout.monospacedDigit())
                .foregroundStyle(message == nil ? Color.secondary : Color.primary)
            SheetActions(onCancel: onCancel) {
                Button("Export") {
                    guard let selection, let filters = choices.filters, choices.hasValidSize else { return }
                    onStart(selection, choices.size, filters)
                }
                .keyboardShortcut(.defaultAction)
                .disabled((files ?? 0) == 0)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private func estimate(_ files: Int?) -> String {
        guard let files, files > 0 else { return "No frames selected for export." }
        let total = files == 1 ? "1 image file" : "\(files.formatted()) image files"
        return choices.skipBlurry || choices.skipDuplicates ? "Up to \(total)" : total
    }

    private func numberField(_ label: String, text: Binding<String>) -> some View {
        TextField("", text: text)
            .accessibilityLabel(label)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: 56)
    }
}
