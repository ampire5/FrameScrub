import FrameScrubCore
import StashKit
import SwiftUI

/// A text field saved on Return or when it loses focus; it may be emptied (an empty `stash-url` turns Stash off).
struct CommitField: View {
    let prompt: String
    @Binding var value: String
    var secure = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(prompt, text: $draft)
            } else {
                TextField(prompt, text: $draft)
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)   // a grouped form aligns its trailing column to the right
        .frame(width: 320)
        .focused($focused)
        .onAppear { draft = value }
        .onSubmit(commit)
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
        .onChange(of: value) { _, new in if !focused { draft = new } }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed != value { value = trimmed }
    }
}

/// Settings → Stash (Stash spec §3.7): the server, its API key, extra path rules, and a check of all three.
struct StashPreferencesView: View {
    @ObservedObject var model: PreferencesModel
    @State private var rules = ""
    @State private var check: String?
    @State private var checking = false
    @FocusState private var rulesFocused: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Stash address") {
                    CommitField(prompt: "http://localhost:9999", value: model.binding(\.stashURL, ["stash-url"]))
                }
                LabeledContent("API key") {
                    CommitField(prompt: "only when Stash has a login", value: model.binding(\.stashAPIKey, ["stash-api-key"]),
                                secure: true)
                }
            } footer: {
                Text("Empty address: no Stash tab on the start screen.").foregroundStyle(.secondary)
            }
            Section {
                TextEditor(text: $rules)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 90)
                    .focused($rulesFocused)
                    .onChange(of: rulesFocused) { _, focused in if !focused { saveRules() } }
            } header: {
                Text("Path rules")
            } footer: {
                Text(#"One per line: a Stash path prefix = a path on this Mac, e.g. S:\Videos=/Volumes/Media/Videos. "#
                     + "Tried before the mounted shares (drive letters go to the PC's S$ shares, \\\\server\\share to the same share).")
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Button("Check") { runCheck() }.disabled(checking || !model.config.stashEnabled)
                    if checking { ProgressView().controlSize(.small) }
                }
                if let check { Text(check).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
        }
        .formStyle(.grouped)
        .onAppear { rules = model.config.stashPathMap.split(separator: ";").joined(separator: "\n") }
    }

    private func saveRules() {
        let joined = rules.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: ";")
        if joined != model.config.stashPathMap { model.binding(\.stashPathMap, ["stash-path-map"]).wrappedValue = joined }
    }

    /// "Stash v0.31.1 · S:\… → /Volumes/S$/…": the server answers and its first scene's file is found on this Mac.
    private func runCheck() {
        saveRules()
        let config = model.config
        guard let url = URL(string: config.stashURL) else { return }
        let client = StashClient(baseURL: url, apiKey: config.stashAPIKey)
        checking = true
        Task { @MainActor in
            defer { checking = false }
            do {
                let version = try await client.version()
                guard let path = try await client.firstScenePath() else { check = "Stash \(version) · no scenes yet"; return }
                let map = StashPathMap(mounts: SMBMount.current(), rules: StashPathRule.parse(config.stashPathMap))
                switch map.resolve(path) {
                case let .local(file):
                    let found = FileManager.default.fileExists(atPath: file.path)
                    check = "Stash \(version) · \(path) → \(file.path)" + (found ? "" : " (not found)")
                case let .needsMount(share):
                    check = "Stash \(version) · \(path) → \(StashSession.unc(share)) is not mounted; it will be on play"
                case .unmapped:
                    check = "Stash \(version) · No share for \(path)"
                }
            } catch {
                check = "Stash does not answer: \(error.localizedDescription)"
            }
        }
    }
}
