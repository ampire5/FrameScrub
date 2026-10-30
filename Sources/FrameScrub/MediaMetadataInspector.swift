import AppKit
import FrameScrubCore
import HomeScreenModel

/// A lazily created inspector. Fixed rows keep their identity; arriving facts replace only changed label values.
/// Reading the catalog and probing an unknown file never run on the main actor.
@MainActor final class MediaMetadataInspector: NSWindowController, NSWindowDelegate {
    private let status = NSTextField(labelWithString: "")
    private var values: [String: NSTextField] = [:]
    private var generation = 0

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 600),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "File Information"
        panel.autorecalculatesKeyViewLoop = true
        super.init(window: panel)
        panel.delegate = self
        let rows = NSStackView()
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 12
        rows.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        rows.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        rows.addArrangedSubview(status)
        for key in ["Name", "Last Viewed", "Picture", "Duration", "Container", "Video", "Audio", "Subtitles", "Tags", "Chapters"] {
            let heading = NSTextField(labelWithString: key)
            heading.font = .boldSystemFont(ofSize: 12)
            let value = NSTextField(wrappingLabelWithString: "…")
            value.isSelectable = true
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            values[key] = value
            rows.addArrangedSubview(heading); rows.addArrangedSubview(value)
            value.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -40).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = rows
        panel.contentView = scroll
        rows.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        panel.center()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ entry: BrowserEntry) {
        MetadataInspectionQueue.shared.cancel(); generation += 1
        let current = generation
        for key in values.keys { set(key, "…") }
        set("Name", entry.name)
        set("Last Viewed", entry.lastViewedAt.map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .medium) } ?? "No saved viewing time")
        if let facts = entry.facts { showFacts(facts) }
        status.stringValue = "Loading saved information…"
        showWindow(nil)
        let url = entry.url
        MetadataInspectionQueue.shared.inspect(url, reading: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, current == self.generation else { return }
                self.status.stringValue = "Reading file information…"
            }
        }, completed: { [weak self] metadata in
            Task { @MainActor [weak self] in
                guard let self, current == self.generation else { return }
                if let metadata { self.apply(metadata) }
                else { self.status.stringValue = "File information is unavailable" }
            }
        })
    }
    func windowWillClose(_ notification: Notification) {
        MetadataInspectionQueue.shared.cancel()
        generation += 1
    }
    private func set(_ key: String, _ text: String) {
        if values[key]?.stringValue != text { values[key]?.stringValue = text }
    }
    private func showFacts(_ facts: FileFacts) {
        if let width = facts.width, let height = facts.height { set("Picture", "\(width) × \(height)") }
        if let duration = facts.duration { set("Duration", RecentFiles.positionText(duration)) }
        if let codec = facts.codec { set("Video", codec) }
    }
    private func apply(_ metadata: MediaMetadata) {
        status.stringValue = "Information checked"
        set("Picture", "Not declared")
        set("Duration", "Not declared")
        showFacts(metadata.facts)
        set("Container", metadata.containerDescription ?? metadata.container)
        for (key, kind) in [("Video", MediaMetadata.Stream.Kind.video), ("Audio", .audio), ("Subtitles", .subtitle)] {
            let streams = metadata.streams.filter { $0.kind == kind }
            let lines = streams.map { stream -> String in
                var parts = ["#\(stream.index) \(stream.codec)"]
                if let profile = stream.profile { parts.append(profile) }
                if let width = stream.codedWidth, let height = stream.codedHeight { parts.append("\(width) × \(height) coded") }
                if let rotation = stream.rotationClockwise, rotation != 0 { parts.append("\(rotation)°") }
                if let sar = stream.sampleAspectRatio { parts.append("SAR \(sar.numerator):\(sar.denominator)") }
                if let rate = stream.frameRate { parts.append(String(format: "%.3f fps", rate.value)) }
                if let transfer = stream.colorTransfer { parts.append(transfer) }
                if let primaries = stream.colorPrimaries { parts.append(primaries) }
                if let layout = stream.channelLayout { parts.append(layout) }
                if let sampleRate = stream.sampleRate { parts.append("\(sampleRate) Hz") }
                if let language = stream.tags["language"] { parts.append(language) }
                if let title = stream.tags["title"] { parts.append(title) }
                return parts.joined(separator: " · ")
            }
            set(key, lines.isEmpty ? "Not declared" : lines.joined(separator: "\n"))
        }
        set("Tags", metadata.tags.isEmpty ? "Not declared" : metadata.tags.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
        set("Chapters", metadata.chapters.isEmpty ? "Not declared" : "\(metadata.chapters.count)")
    }
}
