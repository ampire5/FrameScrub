import Combine
import FrameScrubCore
import SwiftUI

/// The rows of the "Mouse & Trackpad" tab. Edits go through `InputPreferences`, which applies them to the
/// running player first and writes input.conf afterwards.
final class GestureModel: ObservableObject {
    @Published private(set) var rows: [GestureBinding]
    @Published var errorMessage: String?
    private let preferences: InputPreferences

    init(preferences: InputPreferences) {
        self.preferences = preferences
        rows = preferences.bindings
        // Weak self: the preferences object outlives the window and keeps this closure.
        preferences.addObserver { [weak self] _ in
            DispatchQueue.main.async { guard let self else { return }; self.rows = self.preferences.bindings }
        }
    }

    func update(_ old: GestureBinding, _ new: GestureBinding) { run { try self.preferences.replace(old, with: new) } }
    func add(_ row: GestureBinding) { run { try self.preferences.set(row) } }
    func reset() { run { try self.preferences.resetGestures() } }

    private func run(_ edit: () throws -> Void) {
        do {
            try edit()
            errorMessage = nil
        } catch {
            errorMessage = "Cannot write input.conf: \(error.localizedDescription). The change is applied until you quit."
        }
        rows = preferences.bindings
    }
}
