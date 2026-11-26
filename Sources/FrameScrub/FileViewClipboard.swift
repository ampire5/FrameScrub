import AppKit
import HomeScreenModel

/// File View exchanges file URLs with Finder and other apps through the system clipboard.
@MainActor enum FileViewClipboard {
    static func folder(in location: BrowserLocation) -> URL? {
        guard case .folder(let folder) = location, folder.isFileURL else { return nil }
        return folder
    }

    static func copy(_ selection: [BrowserEntry]) {
        let urls = selection.map(\.url).filter(\.isFileURL)
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls.map { $0 as NSURL })
    }

    static var hasFiles: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: options)
    }

    static func files() -> [URL] {
        let items = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: options) ?? []
        return items.compactMap { $0 as? URL }.filter(\.isFileURL)
    }

    private static var options: [NSPasteboard.ReadingOptionKey: Any] { [.urlReadingFileURLsOnly: true] }
}
