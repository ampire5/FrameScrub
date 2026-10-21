import AppKit
import FrameScrubCore
import SwiftUI

/// Carries a `Command` in a menu item's `representedObject`.
final class CommandBox: NSObject {
    let command: Command
    /// The item's title without the key hint.
    let title: String
    init(_ command: Command, title: String = "") {
        self.command = command
        self.title = title
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var controller: PlayerWindowController?
    private(set) var preferences: PreferencesStore!
    private(set) var gestureBindings: GesturePreferences!
    private var preferencesWindow: PreferencesWindowController?
    private let appIcon = AppIconSwitcher()

    /// View › App Icon…: the Dock icon picker (AppIconSwitcher).
    @MainActor @objc private func showIconPicker(_ sender: Any?) { appIcon.showPicker(preferences: preferences) }
    private var pendingURL: URL?
    /// A link that could not be opened before the window existed.
    private var pendingNotice: String?
    /// True for a launch that handed over to an already running instance (single-instance=yes) and is quitting.
    private var isSecondary = false
    private var handOverObserver: NSObjectProtocol?
    /// Set by a Finder/Dock open: the system activates us on its own schedule, so the window is raised again then.
    private var raiseOnActivate = false
    /// The one queue that writes A-B clips (nil for a secondary launch).
    private var clipQueue: ClipQueue?
    /// Set while a "Quit When Done" is waiting for the clip queue to empty.
    private var terminateWhenIdle = false
    /// The Logitech mouse (nil for a secondary launch, and until the first window is up).
    private var mouseBridge: LogiMouseBridge?
    /// The folders' colour (folder-colors.json); nil for a secondary launch, which never opens a file.
    private var folderColors: FolderColors?

    private static let openFileNotification = Notification.Name("com.framescrub.open-file")

    func applicationDidFinishLaunching(_ notification: Notification) {
        StartupTrace.mark("launched")
        let (config, configWarnings) = Config.load()
        if config.singleInstance, let primary = Self.primaryInstance() {
            becomeSecondary(primary)
            return
        }
        NSApp.mainMenu = makeMainMenu()
        let (inputMap, inputWarnings) = InputMap.load(layout: config.keyLayout)
        preferences = PreferencesStore(config: config)
        gestureBindings = GesturePreferences(layout: config.keyLayout)
        let folderColors = FolderColors()
        self.folderColors = folderColors
        let controller = PlayerWindowController(config: config, inputMap: inputMap, preferences: preferences,
                                                folderColors: folderColors)
        preferences.addObserver { [weak controller] in controller?.applyConfig($0) }
        preferences.addObserver { [weak self] in self?.gestureBindings.layout = $0.keyLayout }
        preferences.addObserver { [weak self] in self?.appIcon.apply($0.appIcon) }
        appIcon.apply(config.appIcon)
        gestureBindings.addObserver { [weak controller] in controller?.applyInputMap($0) }
        controller.onDisableSRStill = { [weak self, weak controller] in
            do { try self?.preferences.update(["sr-still"]) { $0.srStill = false } } catch {
                controller?.showMessage("Cannot save sr-still=no: \(error)", duration: 3)
            }
        }
        let clipQueue = ClipQueue()
        clipQueue.onFinished = { [weak self, weak controller, weak clipQueue] job, result in
            switch result {
            case let .success(clip):
                var text = PlayerCore.clipSavedMessage(name: clip.url.lastPathComponent, leadIn: clip.leadIn)
                // A pending "Quit When Done" message would otherwise be replaced for good by this one.
                if self?.terminateWhenIdle == true, let left = clipQueue?.remainingCount, left > 0 {
                    text += "\n" + Self.quittingMessage(left: left)
                    controller?.showMessage(text, duration: 3600)
                } else {
                    controller?.showMessage(text)
                }
                controller?.playHaptic(.done)
            case let .failure(error):
                // The user must see why a clip is missing, so a failure cancels a pending quit.
                self?.replyToTerminate(false)
                controller?.showMessage("Clip failed: \(job.source.lastPathComponent): \(error.localizedDescription)", duration: 5)
                controller?.playHaptic(.error)
            }
        }
        clipQueue.onIdle = { [weak self, weak clipQueue] in
            // The queue can report idle late or twice, so only a really empty queue answers.
            guard let self, clipQueue?.isBusy != true else { return }
            self.replyToTerminate(true)
        }
        controller.setClipQueue(clipQueue)
        self.clipQueue = clipQueue
        self.controller = controller
        observeHandOver()
        controller.showWindow(nil)
        NSApp.activate()
        StartupTrace.mark("window shown")
        // The mouse search runs off the launch path: after the window is up (mouse spec §3.2, §8).
        DispatchQueue.main.async { [weak self, weak controller] in
            guard let self, let controller else { return }
            let bridge = LogiMouseBridge(config: preferences.config, map: controller.currentInputMap)
            mouseBridge = bridge
            controller.attach(bridge)
        }

        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = paths.first {
            controller.open(URL(fileURLWithPath: path))   // a failure stays on screen with its reason
        } else if let url = pendingURL {
            controller.open(url)
        } else {
            controller.showStartScreen()
        }
        let warnings = configWarnings + inputWarnings + (pendingNotice.map { [$0] } ?? [])
        if !warnings.isEmpty { controller.showMessage(warnings.joined(separator: "\n"), duration: 6) }
    }

    /// Finder "Open With", drops on the Dock icon and `framescrub://open?path=` links.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let opened = urls.first else { return }
        // Before anything else, so that the hand-over to the primary instance gets the real path too.
        guard let url = OpenLink.fileURL(from: opened) else {
            let notice = "Cannot open the link: \(opened.absoluteString)"
            if let controller { controller.showMessage(notice, duration: 4) } else if !isSecondary { pendingNotice = notice }
            return
        }
        if isSecondary { Self.postHandOver(path: url.path); return }
        if let controller {
            controller.open(url)
            // A launch brings the window forward itself (pendingURL). For a running app, macOS may refuse our own
            // activate() while the Finder is still active (it cannot yield to us); the activation LaunchServices
            // grants for the open can land after this event, so the window is raised again when it does.
            if preferences?.config.activateOnOpen == true {
                raiseOnActivate = !NSApp.isActive   // already in front: nothing to wait for
                controller.bringToFront()
                NSApp.activate()
            }
        } else {
            pendingURL = url
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // framescrub.conf may have been edited meanwhile (a text editor, icon-mode): its changes apply on switching back.
        if !isSecondary { preferences.reload() }
        guard raiseOnActivate else { return }
        raiseOnActivate = false
        controller?.bringToFront()
    }

    /// Answers a pending `.terminateLater` once; any later call (the idle report and the timeout both come) is a no-op.
    private func replyToTerminate(_ terminate: Bool) {
        guard terminateWhenIdle else { return }
        terminateWhenIdle = false
        NSApp.reply(toApplicationShouldTerminate: terminate)
    }

    private static func quittingMessage(left: Int) -> String {
        "Quitting after \(left) \(left == 1 ? "clip" : "clips")…"
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let clipQueue, clipQueue.isBusy else { return .terminateNow }
        let count = clipQueue.waitingCount + 1
        let alert = NSAlert()
        alert.messageText = count == 1 ? "1 clip is still being saved" : "\(count) clips are still being saved"
        alert.addButton(withTitle: "Quit When Done")   // Return
        let now = alert.addButton(withTitle: "Quit Now")
        now.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")           // Esc
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard clipQueue.isBusy else { return .terminateNow }   // finished while the alert was up
            terminateWhenIdle = true
            let left = clipQueue.waitingCount + 1
            controller?.showMessage(Self.quittingMessage(left: left), duration: 3600)
            return .terminateLater
        case .alertSecondButtonReturn:
            // The cancelled worker deletes its `.part` file first; a stalled read must not hold the quit for long.
            terminateWhenIdle = true
            clipQueue.cancelAll()
            guard clipQueue.isBusy else {
                terminateWhenIdle = false
                return .terminateNow
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.replyToTerminate(true) }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let handOverObserver { DistributedNotificationCenter.default().removeObserver(handOverObserver) }
        controller?.shutdown()   // nil for a secondary launch, which never built a controller
        folderColors?.flush()   // a folder save still waiting for its debounced write
    }

    // MARK: Single instance

    /// The different running copy of this app that launched before us and so must keep running, if any.
    private static func primaryInstance() -> NSRunningApplication? {
        func instance(_ app: NSRunningApplication) -> RunningInstance? {
            guard let key = app.bundleIdentifier ?? app.executableURL?.path else { return nil }
            return RunningInstance(pid: app.processIdentifier, key: key, launchDate: app.launchDate)
        }
        guard let me = instance(.current) else { return nil }
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let others = apps.compactMap(instance)
        guard let primary = SingleInstance.primary(over: me, among: others) else { return nil }
        return apps.first { $0.processIdentifier == primary.pid }
    }

    /// Passes this launch's file to the running instance and quits without ever building a window.
    private func becomeSecondary(_ primary: NSRunningApplication) {
        isSecondary = true
        // We are the active app; the primary's own activate() may be refused unless we yield.
        NSApp.yieldActivation(to: primary)
        let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = paths.first {
            Self.postHandOver(path: URL(fileURLWithPath: path).path)
        } else if let url = pendingURL {
            Self.postHandOver(path: url.path)
        } else {
            Self.postHandOver(path: nil)   // nothing to open: just bring the running window forward
        }
        // A Finder open event can still arrive after launch; application(_:open:) forwards it while we wait.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.terminate(nil) }
    }

    private static func postHandOver(path: String?) {
        DistributedNotificationCenter.default().postNotificationName(
            openFileNotification, object: nil,
            userInfo: path.map { ["path": $0] } ?? [:], deliverImmediately: true)
    }

    private func observeHandOver() {
        handOverObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.openFileNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let self, !self.isSecondary, let controller = self.controller else { return }
            // Any process can post this name, so only an absolute path to an existing regular file is opened.
            if let path = note.userInfo?["path"] as? String, path.hasPrefix("/") {
                let url = URL(fileURLWithPath: path)
                if (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                    controller.open(url)
                }
            }
            controller.bringToFront()
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        controller?.open(url)
    }

    @objc func closeWindow(_ sender: Any?) {
        if let controller, NSApp.keyWindow === controller.window, controller.hasOpenFile {
            controller.closeFile()
        } else {
            (NSApp.keyWindow ?? controller?.window)?.performClose(sender)
        }
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            let tab = AnyView(GestureTableView(model: GestureModel(preferences: gestureBindings)))
            preferencesWindow = PreferencesWindowController(store: preferences, mouseTab: tab)
        }
        preferencesWindow?.show()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        menu.removeAllItems()
        let recent = RecentFiles.existing(NSDocumentController.shared.recentDocumentURLs, hidden: HiddenRecent().paths)
        for url in recent {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            menu.addItem(item)
        }
        if recent.isEmpty {
            let none = NSMenuItem(title: "No Recent Files", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
            return
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        controller?.open(url)
    }

    @objc func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(nil)
        var hidden = HiddenRecent()
        hidden.clear()
        controller?.showStartScreenIfEmpty()
    }

    private static let previewSizes: [(title: String, width: Int)] = [
        ("Off", 0), ("Small", 160), ("Medium", 240), ("Large", 360), ("Extra Large", 480),
    ]

    @objc func setPreviewSize(_ sender: NSMenuItem) {
        let width = sender.tag
        do {
            try preferences.update(["preview", "preview-width"]) {
                $0.preview = width > 0
                if width > 0 { $0.previewWidth = Double(width) }
            }
        } catch {
            controller?.showMessage("Cannot save settings: \(error)", duration: 4)
        }
    }

    private func makePreviewSizeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Preview Size", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Preview Size")
        for size in Self.previewSizes {
            let entry = NSMenuItem(title: size.title, action: #selector(setPreviewSize(_:)), keyEquivalent: "")
            entry.tag = size.width
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc func setABLoopMode(_ sender: NSMenuItem) {
        let mode = ABLoopMode.allCases[sender.tag]
        do { try preferences.update(["ab-loop"]) { $0.abLoop = mode } } catch {
            controller?.showMessage("Cannot save settings: \(error)", duration: 4)
        }
    }

    /// Playback > At B: loop back to A, pause, or back and forth (`ab-loop`; ⇧F / L cycles it).
    private func makeABLoopModeMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "At B", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "At B")
        for (tag, mode) in ABLoopMode.allCases.enumerated() {
            let title = switch mode {
            case .loop: "Loop Back to A"
            case .once: "Pause"
            case .pingPong: "Back and Forth"
            }
            let entry = NSMenuItem(title: title, action: #selector(setABLoopMode(_:)), keyEquivalent: "")
            entry.tag = tag
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc func setSaveUpscaler(_ sender: NSMenuItem) {
        let upscaler: Upscaler = sender.tag == 0 ? .ml : .lanczos
        do { try preferences.update(["save-upscaler"]) { $0.saveUpscaler = upscaler } } catch {
            controller?.showMessage("Cannot save settings: \(error)", duration: 4)
        }
    }

    private func makeUpscalerMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Upscaler for Saved Frames", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Upscaler for Saved Frames")
        for (tag, title) in [(0, "Neural Network"), (1, "Lanczos")] {
            let entry = NSMenuItem(title: title, action: #selector(setSaveUpscaler(_:)), keyEquivalent: "")
            entry.tag = tag
            entry.target = self
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    /// Playback > Colour (colour memory spec §6): the toggles write the file, the saves lift the effective colour to
    /// the folder or framescrub.conf, the resets drop a level's own values. The keys stay input.conf bindings.
    private func makeColorMenu() -> NSMenuItem {
        let item = NSMenuItem(title: "Colour", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Colour")
        for entry: (String, Command)? in [
            ("Auto Colour", .toggleAutoColor), ("Vibrance", .toggleVibrance), nil,
            ("Save Auto Colour for the Folder", .saveAutoColor(folder: true)),
            ("Save Vibrance for the Folder", .saveVibrance(folder: true)),
            ("Save Auto Colour as Default", .saveAutoColor(folder: false)),
            ("Save Vibrance as Default", .saveVibrance(folder: false)), nil,
            ("Reset File Colour", .resetColor(.file)), ("Reset Folder Colour", .resetColor(.folder)),
        ] {
            if let (title, command) = entry {
                submenu.addItem(commandItem(title, command, key: "", modifiers: []))
            } else {
                submenu.addItem(.separator())
            }
        }
        item.submenu = submenu
        return item
    }

    @objc func copyPath(_ sender: Any?) { controller?.copyPath() }
    @objc func largerCards(_ sender: Any?) { controller?.resizeStartCards(.larger) }
    @objc func smallerCards(_ sender: Any?) { controller?.resizeStartCards(.smaller) }
    @objc func defaultCardSize(_ sender: Any?) { controller?.resizeStartCards(.reset) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copyPath(_:)) { return controller?.currentURL != nil }
        if [#selector(largerCards(_:)), #selector(smallerCards(_:)), #selector(defaultCardSize(_:))].contains(item.action) {
            return controller?.showsRecentCards == true
        }
        if item.action == #selector(closeWindow(_:)) {
            let video = NSApp.keyWindow === controller?.window && controller?.hasOpenFile == true
            item.title = video ? "Close Video" : "Close"
        }
        // While a text field (the playlist filter, ⌘G) is typed in, ⌘⌫ deletes text there, never the video.
        if let box = item.representedObject as? CommandBox, box.command == .deleteFile,
           NSApp.keyWindow?.firstResponder is NSText { return false }
        if item.action == #selector(setSaveUpscaler(_:)), let config = preferences?.config {
            item.state = (item.tag == 0) == (config.saveUpscaler == .ml) ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .toggleUpscaler, let config = preferences?.config {
            item.state = config.srStill ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .toggleVibrance, let config = controller?.colorConfig {
            item.state = config.vibranceOn ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .toggleScrubAudio, let config = preferences?.config {
            item.state = config.scrubAudio ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .toggleScrubAudioPitch, let config = preferences?.config {
            item.state = config.scrubAudioPitch == .natural ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .toggleAutoColor, let config = controller?.colorConfig {
            item.state = config.autoColor ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .cycleOntop, let config = preferences?.config {
            item.state = config.ontop ? .on : .off
        }
        if item.action == #selector(setABLoopMode(_:)), let config = preferences?.config {
            item.state = ABLoopMode.allCases[item.tag] == config.abLoop ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, box.command == .playMarks {
            item.state = controller?.playMarksOnly == true ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, item.keyEquivalent.isEmpty {
            let title = box.command == .stats ? (controller?.statsVisible == true ? "Hide Stats" : "Show Stats") : box.title
            showKeyHint(on: item, box: box, title: title)
        }
        if item.action == #selector(setPreviewSize(_:)), let config = preferences?.config {
            let current = config.preview ? Int(config.previewWidth) : 0
            let nearest = Self.previewSizes.map(\.width).min { abs($0 - current) < abs($1 - current) } ?? 0
            item.state = item.tag == nearest ? .on : .off
        }
        if let box = item.representedObject as? CommandBox, case let .resetColor(level) = box.command {
            return controller?.hasOwnColor(level) == true
        }
        return true
    }

    /// Keys handled by input.conf are not menu key equivalents (the menu would take them before the player and
    /// rebinding would stop working), so the key in effect is drawn after the title in the shortcut column's place.
    private func showKeyHint(on item: NSMenuItem, box: CommandBox, title: String) {
        guard let map = controller?.currentInputMap, let hint = KeyHelp.menuHint(for: box.command, in: map) else {
            item.attributedTitle = nil
            item.title = title
            return
        }
        let font = NSFont.menuFont(ofSize: 0)
        let titleWidth = (title as NSString).size(withAttributes: [.font: font]).width
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: max(220, titleWidth + 70))]
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .paragraphStyle: paragraph])
        text.append(NSAttributedString(string: "\t" + hint, attributes: [
            .font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]))
        item.attributedTitle = text
    }

    @objc func runMenuCommand(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? CommandBox else { return }
        controller?.runCommand(box.command)
    }

    func commandItem(_ title: String, _ command: Command, key: String,
                     modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runMenuCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.representedObject = CommandBox(command, title: title)
        item.target = self
        return item
    }

    private func makeMainMenu() -> NSMenu {
        let menu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FrameScrub", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showPreferences(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit FrameScrub", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        menu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        let recentItem = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(title: "Open Recent")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        fileMenu.addItem(recentItem)
        // The start screen's own keys (⌘= / ⌘− / ⌘0, ⌘ + wheel, pinch, the side wheel); listed here to be found in Help.
        // No key on the items: a menu key is taken even while its item is off, and ⌘= / ⌘− zoom a video.
        fileMenu.addItem(withTitle: "Larger Cards", action: #selector(largerCards(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Smaller Cards", action: #selector(smallerCards(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(withTitle: "Default Card Size", action: #selector(defaultCardSize(_:)), keyEquivalent: "").target = self
        fileMenu.addItem(commandItem("Show Saved Frames in Finder", .revealFrames, key: "o", modifiers: [.command, .shift]))
        let copyPath = fileMenu.addItem(withTitle: "Copy Path", action: #selector(copyPath(_:)), keyEquivalent: "c")
        copyPath.keyEquivalentModifierMask = [.command, .option]
        copyPath.target = self
        fileMenu.addItem(commandItem("Move to Trash", .deleteFile, key: "\u{8}"))   // ⌘⌫
        fileMenu.addItem(.separator())
        // ⌘W: the video when the player shows one (close-file), else the window.
        let closeWindow = fileMenu.addItem(withTitle: "Close", action: #selector(closeWindow(_:)), keyEquivalent: "w")
        closeWindow.target = self
        fileItem.submenu = fileMenu
        menu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        // In the player this copies the frame (PlayerWindowController.copy); in a text field, the text.
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(.separator())
        viewMenu.addItem(commandItem("Half Size", .windowScale(0.5), key: "1"))
        viewMenu.addItem(commandItem("Normal Size", .windowScale(1), key: "2"))
        viewMenu.addItem(commandItem("Double Size", .windowScale(2), key: "3"))
        viewMenu.addItem(commandItem("Fit to Screen", .windowFit, key: "4"))
        viewMenu.addItem(commandItem("Float on Top", .cycleOntop, key: "", modifiers: []))   // T stays an input.conf binding
        viewMenu.addItem(commandItem("Show Stats", .stats, key: "", modifiers: []))   // i stays an input.conf binding
        let icon = viewMenu.addItem(withTitle: "App Icon…", action: #selector(showIconPicker(_:)), keyEquivalent: "i")
        icon.keyEquivalentModifierMask = [.control, .option, .command]
        viewMenu.addItem(.separator())
        viewMenu.addItem(makePreviewSizeMenu())
        viewMenu.addItem(commandItem("Upscale Still Frame", .toggleUpscaler, key: "", modifiers: []))   // U stays an input.conf binding
        viewMenu.addItem(makeUpscalerMenu())
        viewMenu.addItem(commandItem("Next Aspect Ratio", .cycleAspect, key: "", modifiers: []))   // a stays an input.conf binding
        viewMenu.addItem(commandItem("Show Playlist", .togglePlaylist, key: "", modifiers: []))   // F8 stays an input.conf binding
        viewMenu.addItem(commandItem("Find in Folder…", .playlistFilter, key: "f"))
        viewMenu.addItem(commandItem("Next Folder Order", .cyclePlaylistSort, key: "", modifiers: []))   // F9 stays an input.conf binding
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)

        let playbackItem = NSMenuItem()
        let playbackMenu = NSMenu(title: "Playback")
        let none: NSEvent.ModifierFlags = []
        for entry: (String, Command)? in [
            ("Play / Pause", .cyclePause), ("Shuttle Back", .shuttleBack), ("Stop", .shuttleStop),
            ("Shuttle Forward", .shuttleForward), nil,
            ("Next Frame", .frameStep), ("Previous Frame", .frameBackStep),
            ("Next Keyframe", .keyframeStep), ("Previous Keyframe", .keyframeBackStep),
            ("Next Scene", .sceneStep), ("Previous Scene", .sceneBackStep), nil,
            ("Back to Before the Last Seek", .revertSeek), nil,
            ("Faster", .stepSpeed(1)), ("Slower", .stepSpeed(-1)), ("Normal Speed", .setSpeed(1)),
            ("Scrub Audio", .toggleScrubAudio), ("Natural Scrub Pitch", .toggleScrubAudioPitch), nil,
            ("Set A-B Range Point", .abLoop), ("Save Frame", .screenshot), ("Export A-B Range…", .exportRange),
            ("Save Marks as Clips…", .saveClip), nil,
            ("Previous Video in Folder", .playlistPrev), ("Next Video in Folder", .playlistNext),
        ] {
            if let (title, command) = entry {
                playbackMenu.addItem(commandItem(title, command, key: "", modifiers: none))
                if command == .abLoop { playbackMenu.addItem(makeABLoopModeMenu()) }
                if command == .saveClip {
                    let marksItem = NSMenuItem(title: "Marks", action: nil, keyEquivalent: "")
                    let marksMenu = NSMenu(title: "Marks")
                    for (title, command): (String, Command) in [
                        ("Mark In", .markIn), ("Mark Out", .markOut), ("Previous Mark Edge", .markPrev),
                        ("Next Mark Edge", .markNext), ("Mark Start to Keyframe", .markSnap),
                        ("Add A-B Loop as Mark", .markLoop), ("Delete Mark Here", .markDelete),
                        ("Delete All Marks", .markClear), ("Play Marks Only", .playMarks),
                    ] {
                        marksMenu.addItem(commandItem(title, command, key: "", modifiers: none))
                    }
                    marksItem.submenu = marksMenu
                    playbackMenu.addItem(marksItem)
                }
            } else {
                playbackMenu.addItem(.separator())
            }
        }
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(makeColorMenu())
        playbackMenu.addItem(.separator())
        playbackMenu.addItem(commandItem("Go to Time or Frame…", .goTo, key: "g"))
        playbackItem.submenu = playbackMenu
        menu.addItem(playbackItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(commandItem("Keyboard Shortcuts", .showKeys, key: "", modifiers: []))   // ? stays an input.conf binding
        helpItem.submenu = helpMenu
        menu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        return menu
    }
}
