import FrameScrubCore
import SwiftUI

/// The sheet `c` opens (cut marks spec §4.1): separate files, one joined file, or everything except the marked.
/// 1 / 2 / 3 choose at once; ↑ ↓ move the highlight, Return takes it, Esc cancels.
struct ClipSheetView: View {
    let summary: ClipSummary
    let onChoose: (ClipMode) -> Void
    let onCancel: () -> Void

    /// The highlighted row. An observable object rather than `@State`, as in ExportSheetView.
    final class Choice: ObservableObject {
        @Published var mode: ClipMode
        init(_ mode: ClipMode) { self.mode = mode }
    }

    @ObservedObject private var choice: Choice
    @FocusState private var focused: Bool

    init(summary: ClipSummary, selected: ClipMode, onChoose: @escaping (ClipMode) -> Void, onCancel: @escaping () -> Void) {
        self.summary = summary
        self.onChoose = onChoose
        self.onCancel = onCancel
        let usable = selected == .joined ? summary.joinedSeconds != nil : selected == .inverted ? summary.invertedSeconds != nil : true
        choice = Choice(usable ? selected : .separate)
    }

    private var modes: [ClipMode] { ClipMode.allCases.filter { available($0) } }

    private func available(_ mode: ClipMode) -> Bool {
        switch mode {
        case .separate: true
        case .joined: summary.joinedSeconds != nil
        case .inverted: summary.invertedSeconds != nil
        }
    }

    /// "0:42.1", "1:02:03".
    static func duration(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        if s >= 3600 { return String(format: "%d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60) }
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    private func detail(_ mode: ClipMode) -> String {
        switch mode {
        case .separate:
            let clips = summary.separateClips == 1 ? "1 clip" : "\(summary.separateClips) clips"
            return "\(clips), \(Self.duration(summary.separateSeconds))" + leadIn(summary.separateLeadIn)
        case .joined:
            return summary.joinedSeconds.map { Self.duration($0) + leadIn(summary.joinedLeadIn) } ?? "Available after indexing"
        case .inverted:
            return summary.invertedSeconds.map(Self.duration) ?? "Available after indexing"
        }
    }

    private func leadIn(_ seconds: Double) -> String {
        seconds > 0.05 ? " (+\(String(format: "%.1f", seconds)) s from keyframes)" : ""
    }

    private func move(_ step: Int) {
        guard let i = modes.firstIndex(of: choice.mode) else { return }
        choice.mode = modes[min(max(i + step, 0), modes.count - 1)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeading(title: "Save clips", detail: summary.segments == 1 ? "1 marked range" : "\(summary.segments) marked ranges")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(ClipMode.allCases.enumerated()), id: \.element) { number, mode in
                    Button { onChoose(mode) } label: {
                        HStack(spacing: 12) {
                            Text("\(number + 1)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .background(.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 4))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.title).font(.body.weight(.medium))
                                Text(detail(mode)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if choice.mode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Color.accentColor)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 48)
                        .background(.primary.opacity(choice.mode == mode ? 0.08 : 0.025),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(choice.mode == mode ? .isSelected : [])
                    .disabled(!available(mode))
                    .keyboardShortcut(KeyEquivalent(Character("\(number + 1)")), modifiers: [])
                }
            }
            SheetActions(onCancel: onCancel) {
                Button("Save") { onChoose(choice.mode) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onAppear { focused = true }
    }
}
