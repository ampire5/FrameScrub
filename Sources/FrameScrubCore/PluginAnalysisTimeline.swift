/// A provider's progress on the source time axis. This is presentation data.
public struct PluginAnalysisTimeline: Equatable, Sendable {
    public struct Fragment: Equatable, Sendable {
        public let id: String
        public let range: ClosedRange<Double>
        public let refined: Bool
    }

    public let jobID: String
    public let running: Bool
    public let covered: [ClosedRange<Double>]
    public let fragments: [Fragment]

    init(_ args: Arguments) throws(PluginMessage.Failure) {
        jobID = try args.cutToken("jobID")
        running = try args.optionalBool("running") ?? false
        let limit = 2_000
        guard let pairs = args.json["covered"] as? [Any], pairs.count <= limit,
              let objects = args.json["fragments"] as? [Any], objects.count <= limit else {
            throw PluginMessage.Failure("covered and fragments must be lists of at most \(limit) items")
        }
        var coverage: [ClosedRange<Double>] = []
        for pair in pairs {
            guard let range = Arguments.pair(pair) else {
                throw PluginMessage.Failure("covered intervals must have two increasing times")
            }
            coverage.append(range)
        }
        var findings: [Fragment] = []
        var ids = Set<String>()
        for value in objects {
            guard let object = value as? [String: Any], let start = object["start"], let end = object["end"],
                  let range = Arguments.pair([start, end]) else {
                throw PluginMessage.Failure("each fragment must have increasing start and end times")
            }
            let fragment = Arguments(object)
            let id = try fragment.cutToken("id")
            guard ids.insert(id).inserted else { throw PluginMessage.Failure("duplicate fragment ID") }
            findings.append(Fragment(id: id, range: range, refined: try fragment.bool("refined")))
        }
        covered = coverage
        fragments = findings
    }
}
