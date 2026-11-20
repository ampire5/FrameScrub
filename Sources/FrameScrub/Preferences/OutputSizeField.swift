import FrameScrubCore
import SwiftUI

/// Picker for `save-scale` / `export-scale`: ×1, ×2, ×4, fit to the screen, or one fixed side in pixels.
struct OutputSizeField: View {
    @Binding var selection: OutputSize
    @Binding var pixelsText: String

    private enum Kind: String, CaseIterable, Identifiable {
        case x1 = "×1", x2 = "×2", x4 = "×4", fit = "Fit to screen", width = "Width", height = "Height"
        var id: String { rawValue }
    }

    private var kind: Kind {
        switch selection {
        case .scale(2): return .x2
        case .scale(4): return .x4
        case .scale: return .x1
        case .fitScreen: return .fit
        case .width: return .width
        case .height: return .height
        }
    }

    private var pixels: Int {
        switch selection {
        case let .width(n), let .height(n): return n
        default: return 3840
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Picker("Output size", selection: Binding(get: { kind }, set: { value, _ in choose(value) })) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if kind == .width || kind == .height {
                TextField("Pixels", text: Binding(get: { pixelsText }, set: { value, _ in typePixels(value) }))
                    .multilineTextAlignment(.trailing)
                    .font(.body.monospacedDigit())
                    .frame(width: 64)
                Text("px").foregroundStyle(.secondary)
            }
        }
    }

    private func choose(_ kind: Kind) {
        switch kind {
        case .x1: selection = .scale(1)
        case .x2: selection = .scale(2)
        case .x4: selection = .scale(4)
        case .fit: selection = .fitScreen
        case .width: selection = .width(pixels); pixelsText = String(pixels)
        case .height: selection = .height(pixels); pixelsText = String(pixels)
        }
    }

    private func typePixels(_ text: String) {
        pixelsText = text
        guard let value = Self.parsePixels(text) else { return }
        let new: OutputSize = kind == .height ? .height(value) : .width(value)
        if new != selection { selection = new }
    }

    static func parsePixels(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), OutputSize.sideRange.contains(value) else { return nil }
        return value
    }
}
