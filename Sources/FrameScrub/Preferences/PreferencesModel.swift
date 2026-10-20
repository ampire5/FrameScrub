import Combine
import FrameScrubCore
import SwiftUI

/// Bridges the SwiftUI controls to `PreferencesStore`. Changes made elsewhere (menus, the SR "Never" answer) show up too.
final class PreferencesModel: ObservableObject {
    @Published private(set) var config: Config
    @Published var errorMessage: String?
    private let store: PreferencesStore

    init(store: PreferencesStore) {
        self.store = store
        config = store.config
        // The store notifies before it writes the file, possibly off the main queue: publish on main.
        store.addObserver { [weak self] config in DispatchQueue.main.async { self?.config = config } }
    }

    /// A binding that writes `keys` when the value changes. Values the controls hand over are already within range.
    func binding<T>(_ keyPath: WritableKeyPath<Config, T>, _ keys: [String]) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in
            do {
                try self.store.update(keys) { $0[keyPath: keyPath] = value }
                self.errorMessage = nil
            } catch {
                self.errorMessage = "Cannot write framescrub.conf: \(error.localizedDescription). The change is applied until you quit."
            }
            self.config = self.store.config
        })
    }

    /// Like `binding`, but rounds to `decimals` places so sliders do not write 0.31276595744680853 to the file.
    func binding(_ keyPath: WritableKeyPath<Config, Double>, _ keys: [String], decimals: Int) -> Binding<Double> {
        let inner = binding(keyPath, keys)
        let factor = pow(10.0, Double(decimals))
        return Binding(get: { inner.wrappedValue }, set: { inner.wrappedValue = ($0 * factor).rounded() / factor })
    }
}
