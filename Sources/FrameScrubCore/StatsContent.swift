import Foundation
import InfoPanelModel
import StashKit

/// What the file is on disk.
public struct StatsFile: Equatable, Sendable {
    public var name: String
    public var folder: String
    public var size: Int?
    public var modified: Date?

    public init(name: String, folder: String, size: Int?, modified: Date?) {
        self.name = name
        self.folder = folder
        self.size = size
        self.modified = modified
    }

    /// Reads the file's size and modification date. Touches the disk: call it off the main thread.
    public static func read(_ url: URL) -> StatsFile {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return StatsFile(name: url.lastPathComponent, folder: url.deletingLastPathComponent().path,
                         size: values?.fileSize, modified: values?.contentModificationDate)
    }
}

/// What the app (not the player) knows about the picture on screen. Lines that read `Label: value` lose that label (the row has its own).
public struct PictureStats: Equatable, Sendable {
    /// The scaler in use: "MetalFX", "Lanczos".
    public var scaler: String
    public var skippedFrames: Int
    public var aspect: String
    public var colour: String
    public var sceneSearch: String?

    public init(scaler: String, skippedFrames: Int, aspect: String, colour: String, sceneSearch: String?) {
        self.scaler = scaler
        self.skippedFrames = skippedFrames
        self.aspect = aspect
        self.colour = colour
        self.sceneSearch = sceneSearch
    }
}

/// A snapshot of the player for the stats. Texts are ready to show; lines the player used to print as `Label: value`
/// (`readCache`, `seek`, `index`) still carry their prefix, which `StatsContent` drops.
public struct PlayerStats: Equatable, Sendable {
    public var format: MediaFormat
    public var width, height, bitDepth, rotation: Int
    public var sampleAspect, frameRate, duration: Double
    public var decoder: String
    public var frame, lastFrame: Int
    public var exactIndex: Bool
    /// "00:00:01.000 / 00:01:27.000".
    public var time: String
    /// "10 / 512 MiB, 40 frames".
    public var cache: String
    public var readCache, seek, index: String?
    public var speed: String
    public var volume: String
    public var saved: Int
    public var marks, abLoop: String?
    public var sharpness, change: String
    public var lastDecodeError, clips: String?
}

/// The stats as sections and rows (spec §4.1). Rows without a value are not built, so sections without rows come out empty
/// and are left out.
public enum StatsContent {
    public static let defaultOrder = ["File", "Stash", "Video", "Audio", "Playback", "Picture", "Diagnostics"]

    public static func sections(player: PlayerStats?, file: StatsFile?, picture: PictureStats?, stash: StashDetailsState?) -> [InfoSection] {
        var sections: [InfoSection] = []
        func add(_ title: String, _ rows: [InfoRow?]) {
            let rows = rows.compactMap { $0 }
            if !rows.isEmpty { sections.append(InfoSection(title: title, rows: rows)) }
        }
        add("File", fileRows(player: player, file: file))
        add("Stash", stashRows(stash))
        if let player {
            add("Video", videoRows(player))
            add("Audio", audioRows(player.format.audio))
            add("Playback", playbackRows(player))
        }
        add("Picture", pictureRows(picture))
        add("Diagnostics", diagnosticsRows(player: player, picture: picture))
        return sections
    }

    /// "1:27", "1:02:03".
    public static func duration(_ seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: Sections

    private static func fileRows(player: PlayerStats?, file: StatsFile?) -> [InfoRow?] {
        [row("Name", file?.name), row("Folder", file?.folder),
         row("Size", file?.size.map(sizeText)), row("Modified", file?.modified.map(dateText)),
         row("Duration", player.map { duration($0.duration) }), row("Container", player?.format.containerText)]
    }

    private static func videoRows(_ p: PlayerStats) -> [InfoRow?] {
        // As shown: a quarter turn swaps the sides.
        let sideways = p.rotation % 180 != 0
        var dimensions = sideways ? "\(p.height) × \(p.width)" : "\(p.width) × \(p.height)"
        if p.sampleAspect != 1, p.height > 0 {
            let aspect = Double(p.width) * p.sampleAspect / Double(p.height)
            dimensions += String(format: ", DAR %.2f", sideways ? 1 / aspect : aspect)
        }
        return [row("Codec", p.format.videoText), row("Dimensions", dimensions), row("Bit depth", "\(p.bitDepth)-bit"),
                row("Frame rate", String(format: "%.3f fps", p.frameRate)), row("Rotation", p.rotation != 0 ? "\(p.rotation)°" : nil),
                row("Decoder", p.decoder)]
    }

    private static func audioRows(_ audio: MediaFormat.Audio?) -> [InfoRow?] {
        guard let audio else { return [] }
        return [row("Codec", audio.codecText), row("Channels", audio.channelsText), row("Sample rate", audio.sampleRateText),
                row("Bit rate", audio.bitRateText)]
    }

    private static func playbackRows(_ p: PlayerStats) -> [InfoRow?] {
        [row("Frame", "\(p.frame) / \(p.lastFrame) (\(p.exactIndex ? "exact" : "approximate") index)"), row("Time", p.time),
         row("Speed", p.speed), row("Volume", p.volume), row("A-B", p.abLoop), row("Marks", p.marks),
         row("Saved", p.saved > 0 ? "\(p.saved)" : nil), row("Sharpness", p.sharpness), row("Change", p.change)]
    }

    private static func pictureRows(_ picture: PictureStats?) -> [InfoRow?] {
        guard let picture else { return [] }
        return [row("Scaler", picture.scaler), labelled("Aspect", picture.aspect, prefix: "Aspect: "),
                labelled("Colour", picture.colour, prefix: "Colour: "), labelled("Scene search", picture.sceneSearch, prefix: "Scenes: ")]
    }

    private static func diagnosticsRows(player p: PlayerStats?, picture: PictureStats?) -> [InfoRow?] {
        guard let p else { return [] }
        return [row("Cache", p.cache), labelled("Read cache", p.readCache, prefix: "Read: "),
                labelled("Seek", p.seek, prefix: "Seek: "), labelled("Index", p.index, prefix: "Index: "), row("Skipped frames", picture.map(\.skippedFrames).flatMap { $0 > 0 ? "\($0)" : nil }),
                row("Last decode error", p.lastDecodeError), row("Clips", p.clips)]
    }

    private static func stashRows(_ state: StashDetailsState?) -> [InfoRow?] {
        switch state {
        case nil: return []
        case .reading?: return [row("Stash", "Reading…")]
        case let .failed(message)?: return [row("Error", message)]
        case let .loaded(d)?:
            return [row("Title", d.title), row("Date", d.date), row("Studio", d.studio),
                    row("Performers", d.performers.joined(separator: ", ")), row("Tags", d.tags.joined(separator: ", ")),
                    row("Rating", d.rating100.map { String(format: "%.1f / 5", Double($0) / 20) }), row("Plays", playsText(d)),
                    row("Watched", d.playDuration > 0 ? duration(d.playDuration) : nil),
                    row("Resume", d.resumeTime > 0 ? duration(d.resumeTime) : nil),
                    row("O count", d.oCounter > 0 ? "\(d.oCounter)" : nil), row("Organized", d.organized ? "yes" : "no"),
                    row("Code", d.code), row("Director", d.director), row("URLs", d.urls.joined(separator: "\n")),
                    row("StashDB", d.stashIDs.map { "\(URL(string: $0.endpoint)?.host ?? $0.endpoint)  \($0.id)" }.joined(separator: "\n")),
                    row("Markers", markersText(d.markers)), row("Files", d.fileCount > 1 ? "\(d.fileCount)" : nil),
                    row("Scene ID", d.id), row("Description", d.details)]
        }
    }

    /// "3 · last 2026-10-18 11:27"; nil with no plays and no date.
    private static func playsText(_ d: StashSceneDetails) -> String? {
        if d.playCount == 0, d.lastPlayedAt == nil { return nil }
        return d.lastPlayedAt.map { "\(d.playCount) · last \(dateText($0))" } ?? "\(d.playCount)"
    }

    /// The count, then a line per marker: "12:34 Title (Tag)".
    private static func markersText(_ markers: [StashSceneDetails.Marker]) -> String? {
        guard !markers.isEmpty else { return nil }
        let lines = markers.map { marker in
            [duration(marker.seconds), marker.title, marker.primaryTag.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        }
        return (["\(markers.count)"] + lines).joined(separator: "\n")
    }

    // MARK: Rows

    private static func row(_ label: String, _ value: String?) -> InfoRow? {
        guard let value, !value.isEmpty else { return nil }
        return InfoRow(label: label, value: value)
    }

    /// A row under the fixed `label` (spec §4.1) from a line the app or player prints as `Prefix: value`; the prefix is
    /// dropped when the line has it.
    private static func labelled(_ label: String, _ line: String?, prefix: String) -> InfoRow? {
        guard let line else { return nil }
        return row(label, line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : line)
    }

    /// "734.0 MB" (decimal, as Loupe), "2.50 GB" from 1 000 MB.
    private static func sizeText(_ bytes: Int) -> String {
        let megabytes = Double(bytes) / 1_000_000
        return megabytes >= 1000 ? String(format: "%.2f GB", megabytes / 1000) : String(format: "%.1f MB", megabytes)
    }

    /// "2024-05-01 18:30", local time.
    private static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
