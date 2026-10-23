import Foundation

/// An action a plugin page declares: `plugin-action <name>` runs it; `label` names it in the key help; `key` is the
/// page's suggested chord, bound only where the user's keys leave it free (`InputMap.merging`).
public struct PluginAction: Equatable, Sendable {
    public let name: String
    public let label: String
    public let key: KeyChord?

    public init(name: String, label: String, key: KeyChord?) {
        self.name = name
        self.label = label
        self.key = key
    }
}

/// What became of a page action's key: bound (`reason` nil) or refused (`key taken`, `user binding`, `not a key`).
public struct PluginBinding: Equatable, Sendable {
    public let name: String
    public let key: KeyChord?
    public let reason: String?

    public init(name: String, key: KeyChord?, reason: String?) {
        self.name = name
        self.key = key
        self.reason = reason
    }
}

public enum PluginActions {
    /// 1–32 characters of `a-z 0-9 - _`.
    public static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_"
        }
    }

    /// The page's action list `[{name, label, key?}]`; one bad entry refuses the whole list.
    public static func parse(_ list: [[String: Any]]) -> Result<[PluginAction], PluginMessage.Failure> {
        var actions: [PluginAction] = []
        for (i, entry) in list.enumerated() {
            guard let name = entry["name"] as? String, isValidName(name) else {
                return .failure(.init("actions[\(i)].name must be 1-32 of a-z 0-9 - _"))
            }
            guard let label = entry["label"] as? String, (1...60).contains(label.count) else {
                return .failure(.init("actions[\(i)].label must be 1-60 characters"))
            }
            var key: KeyChord?
            if let value = entry["key"], !(value is NSNull) {
                guard let text = value as? String, !text.contains(where: \.isWhitespace),
                      let chord = KeyChord.parse(text) else {
                    return .failure(.init("actions[\(i)].key is not a key"))
                }
                key = chord
            }
            guard !actions.contains(where: { $0.name == name }) else {
                return .failure(.init("duplicate name \(name)"))
            }
            actions.append(PluginAction(name: name, label: label, key: key))
        }
        return .success(actions)
    }
}

/// What the player does with the declared actions, apart from the window.
public enum PluginActionPolicy {
    /// A key bound to `plugin-action <name>` reaches the page only while the panel is shown and the page declared `name`.
    public static func shouldDispatch(_ name: String, declared: [PluginAction], shown: Bool) -> Bool {
        shown && declared.contains { $0.name == name }
    }

    /// The actions whose keys are bound: all of them while the panel is shown, none while it is hidden.
    public static func bindable(_ declared: [PluginAction], shown: Bool) -> [PluginAction] {
        shown ? declared : []
    }
}
