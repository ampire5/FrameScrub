import Foundation
import HomeScreenModel

/// What the playlist strip says of a file (spec 2026-10-27-playlist-strip, «Row content»), from what is already known:
/// the facts Home's posters learned, where the file was left, its size and date. Nothing here reads the file. Words
/// as Home's cards write them (`FileFactsText`).
public struct PlaylistRowFacts: Equatable, Sendable {
    /// Under the name: `2:14:05 · UHD · HEVC`; without facts, the size; with neither, empty.
    public let detail: String
    /// The share before where the file was left, for the bar on its picture; nil unplayed or (nearly) finished.
    public let progress: Double?
    /// The browsed row's card, a line each: size and date; pixels and stream; how much was watched.
    public let card: [String]

    /// A file is finished from here on: no bar.
    public static let finished = 0.98

    public init(facts: FileFacts?, resume: ResumeEntry?, size: Int64?, date: Date?) {
        let duration = facts?.duration ?? resume?.duration
        var parts: [String] = []
        if let duration, duration > 0 { parts.append(StatsContent.duration(duration)) }
        if let facts, let resolution = FileFactsText.resolution(facts) { parts.append(resolution) }
        if let codec = facts?.codec, !codec.isEmpty { parts.append(codec) }
        let sizeText = size.map(FileFactsText.size)
        if facts == nil || parts.isEmpty, let sizeText { parts.append(sizeText) }
        detail = parts.joined(separator: " · ")

        let share = RecentFiles.progress(position: resume?.position, duration: duration)
        progress = share.flatMap { $0 < Self.finished ? $0 : nil }

        var card: [String] = []
        let first = [sizeText, date.map { $0.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }
        if !first.isEmpty { card.append(first.joined(separator: " · ")) }
        if let facts, let w = facts.width, let h = facts.height, w > 0, h > 0 {
            card.append((["\(w) × \(h)"] + [FileFactsText.stream(facts)].compactMap { $0 }).joined(separator: " · "))
        }
        if let progress { card.append("Watched \(Int((progress * 100).rounded())) %") }
        self.card = card
    }
}
