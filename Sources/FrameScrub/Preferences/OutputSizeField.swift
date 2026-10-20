import FrameScrubCore
import SwiftUI

/// Picker for `save-scale` / `export-scale`: ×1, ×2, ×4, fit to the screen, or one fixed side in pixels.
struct OutputSizeField: View {
    @Binding var selection: OutputSize
    /// The typed pixel count (a text field, so a value typed just before Enter is already in `selection`).
    @StateObject private var typed: Typed

    private final class Typed: ObservableObject {
        @Published var text: String
        init(_ text: String) { self.text = text }
    }

    init(selection: Binding<OutputSize>) {
        _selection = selection
        let initial: Int
        switch selection.wrappedValue {
        case let .width(n), let .height(n): initial = n
        default: initial = 3840
        }
        _typed = StateObject(wrappedValue: Typed(String(initial)))
    }

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
        HStack {
            Picker("", selection: Binding(get: { kind }, set: choose)) {
                ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            if kind == .width || kind == .height {
                TextField("px", text: Binding(get: { typed.text }, set: { typed.text = $0; typePixels($0) }))
                    .onSubmit { typed.text = String(pixels) }
                    .frame(width: 70)
                Text("px")
            }
        }
        // Follow changes made elsewhere (the typed text itself already equals `selection` while typing).
        .onChange(of: selection) { _, new in
            switch new {
            case let .width(n), let .height(n): if Int(typed.text.trimmingCharacters(in: .whitespaces)) != n { typed.text = String(n) }
            default: break
            }
        }
    }

    private func choose(_ kind: Kind) {
        switch kind {
        case .x1: selection = .scale(1)
        case .x2: selection = .scale(2)
        case .x4: selection = .scale(4)
        case .fit: selection = .fitScreen
        case .width: selection = .width(pixels); typed.text = String(pixels)
        case .height: selection = .height(pixels); typed.text = String(pixels)
        }
    }

    /// Applies the text on every keystroke when it is a valid side; otherwise the last valid size stays.
    private func typePixels(_ text: String) {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), OutputSize.sideRange.contains(value) else { return }
        let new: OutputSize = kind == .height ? .height(value) : .width(value)
        if new != selection { selection = new }
    }

}
