import FrameScrubCore
import SwiftUI

/// Gesture bindings: one row per device, axis and modifier set.
struct GestureTableView: View {
    @ObservedObject var model: GestureModel

    private enum Kind: String, CaseIterable, Identifiable {
        case scrub = "Scrub frames", scrubFast = "Scrub frames fast", seek = "Seek (seconds)", volume = "Volume",
             speed = "Speed (factor)", speedStep = "Speed (step)", playlist = "Previous / next video", ignore = "Nothing", zoom = "Zoom (not available yet)"
        var id: String { rawValue }
    }

    private static func kind(of action: GestureActionKind) -> Kind {
        switch action {
        case .scrub: return .scrub
        case .scrubFast: return .scrubFast
        case .seek: return .seek
        case .volume: return .volume
        case .speed: return .speed
        case .speedStep: return .speedStep
        case .playlist: return .playlist
        case .ignore: return .ignore
        case .zoom, .zoomContinuous: return .zoom
        }
    }

    private static func action(for kind: Kind, keeping old: GestureActionKind) -> GestureActionKind {
        switch kind {
        case .scrub: return .scrub
        case .scrubFast: return .scrubFast
        case .seek: if case .seek = old { return old }; return .seek(5, .byConfig)
        case .volume: if case .volume = old { return old }; return .volume(2)
        case .speed: if case .speed = old { return old }; return .speed(1.1)
        case .speedStep: return .speedStep
        case .playlist: return .playlist
        case .ignore: return .ignore
        case .zoom: return old
        }
    }

    private static func parameter(of action: GestureActionKind) -> Double? {
        switch action {
        case let .seek(v, _), let .volume(v), let .speed(v): return v
        default: return nil
        }
    }

    private static func with(parameter value: Double, _ action: GestureActionKind) -> GestureActionKind {
        switch action {
        case let .seek(_, precision): return .seek(max(0.001, value), precision)
        case .volume: return .volume(max(0.1, value))
        case .speed: return .speed(max(1.001, value))
        default: return action
        }
    }

    private func title(_ row: GestureBinding) -> String {
        var parts: [String] = []
        if row.modifiers.contains(.ctrl) { parts.append("⌃") }
        if row.modifiers.contains(.alt) { parts.append("⌥") }
        if row.modifiers.contains(.shift) { parts.append("⇧") }
        if row.modifiers.contains(.meta) { parts.append("⌘") }
        let device = row.device == .trackpad ? "Trackpad" : row.device == .wheel ? "Mouse wheel" : "Pinch"
        let axis = row.device == .pinch ? "" : (row.axis == .horizontal ? " ←→" : " ↑↓")
        let held = row.modifiers.contains(.rightButton) ? "RMB + " : ""    // the right mouse button is held
        return held + parts.joined() + (parts.isEmpty ? "" : " ") + device + axis
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A Form, not a List: a List fills its rows only once it is on screen, so the first show of the tab stalled.
            Form {
                Section { ForEach(model.rows, id: \.idString) { row in rowView(row) } }
            }
            .formStyle(.grouped)
            HStack {
                Menu("Add binding") {
                    ForEach([GestureDevice.trackpad, .wheel], id: \.rawValue) { device in
                        ForEach([GestureAxis.horizontal, .vertical], id: \.rawValue) { axis in
                            Menu("\(device == .trackpad ? "Trackpad" : "Mouse wheel") \(axis == .horizontal ? "←→" : "↑↓")") {
                                modifierItem(device, axis, [.shift], "⇧")
                                modifierItem(device, axis, [.alt], "⌥")
                                modifierItem(device, axis, [.shift, .alt], "⇧⌥")
                                modifierItem(device, axis, [.ctrl], "⌃")
                                modifierItem(device, axis, [.rightButton], "Right button")
                            }
                        }
                    }
                }.frame(width: 130)
                Spacer()
                Button("Reset to defaults") { model.reset() }
            }
            if let message = model.errorMessage { Text(message).foregroundColor(.red).font(.callout) }
        }.padding(.horizontal, 8).padding(.vertical, 12)
    }

    /// The row as the model holds it now (same gesture), so an edit never builds on a stale captured copy.
    private func current(of row: GestureBinding) -> GestureBinding {
        model.rows.first { $0.sameGesture(as: row) } ?? row
    }

    private func rowView(_ row: GestureBinding) -> some View {
        let isZoom = Self.kind(of: row.action) == .zoom
        // Width budget (window 560): tab padding 2x8 + list insets ~2x10 = ~524 usable;
        // 150 + 180 + 56 + Invert ~65 + 3 gaps x 6 = ~469, leaving ~55 spare.
        return HStack(spacing: 6) {
            Text(title(row)).lineLimit(1).truncationMode(.tail).help(title(row)).frame(width: 150, alignment: .leading)
            Picker("", selection: Binding(get: { Self.kind(of: row.action) }, set: { kind in
                var new = current(of: row)
                new.action = Self.action(for: kind, keeping: new.action)
                model.update(current(of: row), new)
            })) {
                // Zoom is listed only on rows that already have it; it cannot be chosen.
                ForEach(Kind.allCases.filter { $0 != .zoom || isZoom }) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 180)
            // Fixed columns, empty where a row has no such setting, so the Invert boxes line up.
            Group {
                if let value = Self.parameter(of: row.action) {
                    TextField("", value: Binding(get: { value }, set: { number in
                        var new = current(of: row)
                        new.action = Self.with(parameter: number, new.action)
                        model.update(current(of: row), new)
                    }), formatter: Self.numberFormatter).textFieldStyle(.roundedBorder)
                } else {
                    Color.clear
                }
            }
            .frame(width: 56, height: 20)
            if row.action != .ignore && row.action != .zoomContinuous {
                Toggle("Invert", isOn: Binding(get: { row.invert }, set: { value in
                    var new = current(of: row)
                    new.invert = value
                    model.update(current(of: row), new)
                }))
                .toggleStyle(.checkbox)
            }
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    /// New rows start as "Nothing" on a free modifier combination; the user then picks the action.
    /// Adding a gesture that already has a row does nothing.
    private func modifierItem(_ device: GestureDevice, _ axis: GestureAxis, _ modifiers: Modifiers, _ title: String) -> some View {
        let new = GestureBinding(device: device, axis: axis, modifiers: modifiers, action: .ignore)
        let exists = model.rows.contains { $0.sameGesture(as: new) }
        return Button(title) { if !exists { model.add(new) } }.disabled(exists)
    }
}

/// Identifies a row by its gesture only, so editing the action keeps the row's identity; unique because the
/// model holds one row per (device, axis, modifiers) and a pinch row always has the horizontal axis.
private extension GestureBinding {
    var idString: String { "\(device.rawValue)/\(axis.rawValue)/\(modifiers.rawValue)" }
}
