import AppKit
import FrameScrubCore
import Observation
import SwiftUI

/// Shared by the File menu and settings. Nothing reads the database until explicitly shown or invoked.
@MainActor @Observable public final class MediaCacheActions {
    public static let shared = MediaCacheActions()
    public private(set) var statistics: MediaCatalog.Statistics?
    public private(set) var busy = false
    public private(set) var message: String?
    public enum Command: Sendable { case clearImages, clearAll, cleanUp }

    public func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do { statistics = try await Task.detached(priority: .utility) { try MediaCatalog.shared.statistics() }.value }
        catch { message = "Could not read media cache: \(error.localizedDescription)" }
    }

    public func run(_ command: Command) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        if command != .cleanUp {
            let alert = NSAlert()
            alert.messageText = command == .clearImages ? "Clear thumbnail cache?" : "Clear media cache?"
            alert.informativeText = "Cached data will be rebuilt when needed. Viewing history, playback positions, marks and colour settings are kept."
            alert.addButton(withTitle: "Clear")
            alert.addButton(withTitle: "Cancel")
            let response: NSApplication.ModalResponse
            if let window = NSApp.keyWindow { response = await alert.beginSheetModal(for: window) }
            else { response = alert.runModal() }
            guard response == .alertFirstButtonReturn else { return }
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                let catalog = MediaCatalog.shared
                var count = 0
                switch command {
                case .clearImages: try await catalog.clearImages()
                case .clearAll: try await catalog.clear()
                case .cleanUp: count = try await catalog.cleanUpLocalFiles()
                }
                while try catalog.reclaimStep(allowLegacyRebuild: command != .cleanUp) { await Task.yield() }
                return (try catalog.statistics(), count)
            }.value
            statistics = result.0
            message = command == .cleanUp ? "Removed \(result.1) stale cache records. Offline and network volumes were skipped." : "Cache cleared. Visible images may remain in memory until reopened."
        } catch { message = "Cache operation failed: \(error.localizedDescription)" }
    }
}

struct MediaCacheView: View {
    private let actions = MediaCacheActions.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let stats = actions.statistics {
                Text("\(stats.images) thumbnails · \(stats.metadata) metadata records")
                Text("Image payloads: \(ByteCountFormatter.string(fromByteCount: Int64(stats.imageBytes), countStyle: .file)) · Database on disk: \(ByteCountFormatter.string(fromByteCount: stats.diskBytes, countStyle: .file))")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Text("Media cache").foregroundStyle(.secondary) }
            HStack {
                Button("Refresh") { Task { await actions.refresh() } }
                Button("Clean Up") { Task { await actions.run(.cleanUp) } }
                Button("Clear Thumbnails…") { Task { await actions.run(.clearImages) } }
                Button("Clear Media Cache…") { Task { await actions.run(.clearAll) } }
            }.disabled(actions.busy)
            if actions.busy { Text("Working…").font(.caption) }
            if let message = actions.message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .task { await actions.refresh() }
    }
}
