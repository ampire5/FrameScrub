import Combine
import FrameScrubCore
import Foundation

/// The rows of the gesture table (Mouse & Trackpad). Edits go through `InputPreferences`, which applies them to the
/// running player first and writes input.conf afterwards.
public final class GestureTableModel: ObservableObject {
    @Published private(set) var rows: [GestureBinding]
    @Published var errorMessage: String?
    private let preferences: InputPreferences

    public init(preferences: InputPreferences) {
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

    /// What the window's search finds the table by: each row's gesture and action as the table names them.
    public static func searchTexts(_ rows: [GestureBinding]) -> [String] {
        rows.flatMap { [GestureTableView.title(of: $0), GestureTableView.actionTitle(of: $0.action)] }
    }

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
