import Foundation
import QuartzCore

/// Bounded recent percentiles with lifetime counts. Quantiles use nearest rank.
public struct DiagnosticSamples: Sendable {
    public struct Summary: Codable, Sendable {
        public let count: Int, retained: Int, over20: Int
        public let p50: Double, p95: Double, max: Double, mean: Double
    }
    private let capacity: Int
    private var values: [Double] = []
    private var cursor = 0, count = 0, over20 = 0
    private var maximum = 0.0, sum = 0.0
    public init(capacity: Int = 2048) { self.capacity = max(1, capacity) }
    public mutating func add(_ value: Double) {
        guard value.isFinite, value >= 0 else { return }
        count += 1; sum += value; if value > 20 { over20 += 1 }; maximum = max(maximum, value)
        if values.count < capacity { values.append(value) }
        else { values[cursor] = value; cursor = (cursor + 1) % capacity }
    }
    public func summary() -> Summary {
        let sorted = values.sorted()
        func q(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[max(0, Int(ceil(Double(sorted.count) * p)) - 1)] }
        return Summary(count: count, retained: values.count, over20: over20, p50: q(0.5), p95: q(0.95), max: maximum, mean: count > 0 ? sum / Double(count) : 0)
    }
}

/// Main-thread presentation accounting: redraws, stale callbacks and a new file are distinct from new frames.
public struct PresentationLedger: Sendable {
    public struct Ticket: Sendable {
        fileprivate let epoch: UUID, serial: Int, playbackPeriod: Int
        public let arrivedAt: Double, playing: Bool
    }
    private var epoch = UUID(), serial = 0, lastSubmitted = 0, lastPresented = 0
    private var pending: Int?
    private var playbackPeriod = 0
    public private(set) var replacedBeforeSubmission = 0, submitted = 0, presented = 0
    public init() {}
    public mutating func arrive(at time: Double, playing: Bool) -> Ticket {
        if pending != nil { replacedBeforeSubmission += 1 }
        serial += 1; pending = serial
        return Ticket(epoch: epoch, serial: serial, playbackPeriod: playbackPeriod, arrivedAt: time, playing: playing)
    }
    public mutating func advancePlaybackPeriod() { playbackPeriod += 1 }
    public func isCurrentPlaybackPeriod(_ ticket: Ticket) -> Bool {
        ticket.epoch == epoch && ticket.playbackPeriod == playbackPeriod
    }
    public mutating func submit(_ ticket: Ticket) {
        guard ticket.epoch == epoch else { return }
        if pending == ticket.serial { pending = nil }
        if ticket.serial > lastSubmitted { lastSubmitted = ticket.serial; submitted += 1 }
    }
    /// First physical presentation of this ticket; milliseconds since delivery to the view.
    public mutating func present(_ ticket: Ticket, at time: Double) -> Double? {
        guard ticket.epoch == epoch, ticket.serial > lastPresented, time >= ticket.arrivedAt else { return nil }
        lastPresented = ticket.serial; presented += 1
        return (time - ticket.arrivedAt) * 1000
    }
    public mutating func reset() { self = Self() }
}

/// Opt-in, bounded instrumentation. Nothing writes on the main/render/decode queues.
/// Groups contain generated configuration labels only, never media names or paths.
public final class PlaybackDiagnostics: @unchecked Sendable {
    public static let shared = PlaybackDiagnostics()
    public static var enabled: Bool { shared.destination != nil }
    private let destination: URL?
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "framescrub.diagnostics", qos: .utility)
    private var groups: [String: [String: DiagnosticSamples]] = [:]
    private var order: [String] = [], scheduled = false
    private let started = CACurrentMediaTime()
    private init() {
        let path = ProcessInfo.processInfo.environment["FRAMESCRUB_PIPELINE_REPORT"]
        destination = path.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    }
    public static func now() -> Double { CACurrentMediaTime() }
    public func record(_ metric: String, _ value: Double, group: String) {
        guard destination != nil, value.isFinite, value >= 0 else { return }
        let start = lock.withLock { () -> Bool in
            if groups[group] == nil {
                if order.count == 16 { groups.removeValue(forKey: order.removeFirst()) }
                order.append(group); groups[group] = [:]
            }
            // Instrumentation calls use a finite metric vocabulary; cap defensively as well.
            if groups[group]![metric] != nil || groups[group]!.count < 32 {
                groups[group]![metric, default: DiagnosticSamples()].add(value)
            }
            if scheduled { return false }; scheduled = true; return true
        }
        if start { writer.asyncAfter(deadline: .now() + 5) { [self] in writeSnapshot() } }
    }
    public func flush(completion: @escaping @Sendable () -> Void = {}) {
        guard destination != nil else { completion(); return }
        writer.async { [self] in writeSnapshot(); completion() }
    }
    private func writeSnapshot() {
        guard let destination else { return }
        let snapshot = lock.withLock { () -> [String: [String: DiagnosticSamples]] in
            scheduled = false; return groups
        }
        let summaries = snapshot.mapValues { $0.mapValues { $0.summary() } }
        struct Report: Encodable {
            let schema = 1
            let elapsedSeconds: Double
            let percentileScope = "Most recent 2048 samples per metric; counts/max/over20 cover all samples in retained groups. Last 16 configuration groups."
            let groups: [String: [String: DiagnosticSamples.Summary]]
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(Report(elapsedSeconds: CACurrentMediaTime() - started, groups: summaries))
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
        } catch { NSLog("Playback diagnostics: cannot write report: %@", error.localizedDescription) }
    }
}
