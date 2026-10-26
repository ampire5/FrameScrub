import Foundation

/// Which build this is: `scripts/make-app.sh` bakes the git commit, branch, commit date, whether the tree had
/// uncommitted changes, and the build date into Info.plist (`FSBuild*`), so About and Settings can say it. A build run
/// with `swift run` or from the tests has no such keys.
public struct BuildInfo: Equatable, Sendable {
    public var hash: String
    public var branch: String
    public var commitDate: String
    public var dirty: Bool
    public var buildDate: String

    public init(hash: String, branch: String, commitDate: String, dirty: Bool, buildDate: String) {
        self.hash = hash
        self.branch = branch
        self.commitDate = commitDate
        self.dirty = dirty
        self.buildDate = buildDate
    }

    /// The keys `make-app.sh` wrote; nil without a commit hash.
    public init?(infoDictionary: [String: Any]) {
        func value(_ key: String) -> String { (infoDictionary[key] as? String) ?? "" }
        guard !value("FSBuildHash").isEmpty else { return nil }
        self.init(hash: value("FSBuildHash"), branch: value("FSBuildBranch"), commitDate: value("FSBuildCommitDate"),
                  dirty: value("FSBuildDirty") == "1", buildDate: value("FSBuildDate"))
    }

    /// The running app's.
    public static var current: BuildInfo? { BuildInfo(infoDictionary: Bundle.main.infoDictionary ?? [:]) }

    /// "experiments 793b52f + uncommitted changes · committed 2026-10-26 07:40 · built 2026-10-26 08:01"
    public var line: String {
        let head = [branch, hash].filter { !$0.isEmpty }.joined(separator: " ") + (dirty ? " + uncommitted changes" : "")
        return [head, commitDate.isEmpty ? "" : "committed \(commitDate)", buildDate.isEmpty ? "" : "built \(buildDate)"]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    public static func line(of info: BuildInfo?) -> String {
        info?.line ?? "Development build (not made by scripts/make-app.sh)"
    }
}
