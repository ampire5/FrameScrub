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
            return summary.joinedSeconds.map { Self.duration($0) + leadIn(summary.joinedLeadIn) } ?? "wait for the index"
        case .inverted:
            return summary.invertedSeconds.map(Self.duration) ?? "wait for the index"
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
        VStack(alignment: .leading, spacing: 10) {
            Text(summary.segments == 1 ? "Save 1 mark as clips" : "Save \(summary.segments) marks as clips").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(ClipMode.allCases.enumerated()), id: \.element) { number, mode in
                    Button { onChoose(mode) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(number + 1)").monospacedDigit().foregroundStyle(.secondary)
                            Text(mode.title)
                            Text(detail(mode)).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(choice.mode == mode ? Color.accentColor.opacity(0.25) : Color.clear))
                    }
                    .buttonStyle(.plain)
                    .disabled(!available(mode))
                    .keyboardShortcut(KeyEquivalent(Character("\(number + 1)")), modifiers: [])
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onChoose(choice.mode) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 480)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onAppear { focused = true }
    }
}
