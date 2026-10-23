import AppKit
import FrameScrubCore
import WebKit

/// A web page beside the video: a plugin. The page drives the player through `window.framescrub` and hears the
/// player's state through it; the player knows nothing of what the page is for.
///
/// The bridge, version 1 (`framescrub.version`):
///
/// Commands. Each verb posts a command and forgets it; one that fails fires the `error` event with the reason.
/// `request(cmd, args)` posts the same command and returns a Promise that resolves with the command's result (undefined
/// for the verbs below) or rejects with an Error whose message says what was wrong (unknown command, missing or mistyped
/// argument, a refused open, the failures named below).
///
///     framescrub.seek(t)              seek to `t` seconds (not negative)
///     framescrub.play()  .pause()
///     framescrub.step(n)              `n` frames forward, negative backward
///     framescrub.loop(a, b)           an A-B loop in seconds, `b` above `a`;  loop(null) clears it
///     framescrub.segments(list, {lock?, advance?})
///                                     lock playback and scrubbing to segments = [[a, b], …] in seconds (each `b` above
///                                     `a`); lock (default true), advance "repeat" | "next" (default: segment-advance);
///                                     list [] clears the set (request("segments", {segments, lock?, advance?}) too);
///                                     fails "no segment inside the file" when none falls inside the open file
///     framescrub.lock(on)             lock to the segments or release them; fails "no segments" without any
///     framescrub.goSegment(i)         seek to the start of segment i (from 0, a whole number); fails "no such
///                                     segment" out of range
///     framescrub.actions(list)        declare the page's actions, list = [{name, label, key?}] (name 1-32 of a-z 0-9 - _,
///                                     label 1-60 characters, key in input.conf chord syntax such as "Alt+1"); replaces any
///                                     earlier list, [] withdraws them. A key is bound only where the user's keys leave it
///                                     free; a name the user bound to `plugin-action <name>` in input.conf keeps their key.
///                                     An unknown key name is accepted but may never be pressable. The actions are listed
///                                     in the key help. They belong to the loaded page: they stay while the panel is hidden
///                                     (keys are bound only while it is shown) and are dropped when a new page commits
///                                     (a link, a reload) or the page's process dies; a navigation that fails or is cancelled
///                                     leaves them. A reply sent while the panel is hidden says what the keys will become
///                                     once it is shown. Only keyboard chords bind: a mouse button, wheel, swipe or pinch
///                                     is refused with reason "not a key"
///     framescrub.open(o)              o = {path, t?, segments?, lock?, advance?} a local video (absolute path; the first
///                                     time a page's origin asks, the user is asked to allow it), or {scene, paths?, t?,
///                                     segments?, lock?, advance?} a Stash scene found on the shares or streamed from
///                                     Stash (stash-stream); without `paths` they are asked of Stash. A single
///                                     `seg: [a, b]` still counts as one segment
///     framescrub.focusPlayer()        keys go to the player again (the page's Esc, usually)
///     framescrub.request(cmd, args)   any of the above by name, with a reply: request("seek", {t: 12})
///
/// Requests with an answer (they need a file open, else they reject):
///
///     request("info")                 {path, name, fps, duration, durationFrames, width, height, rotation, codec,
///                                     source: "file" | "stream"} — for a stream, path is Stash's stream URL
///     request("marks")                {loop: [a, b] | null, loopFrames: [a, b] | null, segments: [{start, end,
///                                     startFrame, endFrame}], openFrame, openStart} — the A-B range and the cut marks
///     request("playlist")             {index, count, total, name} — the file's place in its folder (index from 0)
///     request("frame", {t | frame, maxSize?})
///                                     {t, frame, width, height, dataURL} — that frame as a JPEG data URL fitted into
///                                     maxSize x maxSize pixels (16…512, default 512); decoded beside playback
///
///     request("actions", {actions})  {bound: [{key, name}], refused: [{key, name, reason}]} — what became of each key
///                                     (reason "key taken", "user binding" or "not a key"); actions without a key are in neither list
///
/// State. `framescrub.state` is the latest state; `framescrub.onstate = s => …` and the window event "framescrubstate"
/// (`event.detail`) hear each change, at most ten times a second while frames show:
///
///     {ready, path, name, scene, t, frame, fps, duration, durationFrames, playing, loop: [a, b] | null,
///      segments: {list: [[a, b], …], current: i | null, locked, advance} | null, visible}
///
/// Events. `framescrub.on<name> = detail => …`, or the window event "framescrub<name>" with `event.detail`:
///
///     focus / blur                    the panel took the keyboard / gave it back (View › Focus Plugin Panel, ⌃⌥⌘P,
///                                     brings keys to the page; focusPlayer() returns them)
///     fileopened                      {path, scene, source: "file" | "stream"} once a file is open, however it was
///                                     opened; always before any `segment` event for that file (a link's or open's
///                                     segments are applied after it)
///     segment                         {current: i | null, locked} when the current segment or the lock changes, playback
///                                     included
///     action                          {name, t, frame} when the user presses a key bound to the page's action `name` (not
///                                     repeated while held); t and frame are those on screen, not a seek's target
///     error                           a reason string, when a verb (sent without a reply) failed
///
/// Keys. While the panel has the keyboard, a key the page does not handle goes on to the player as if the player had
/// it (its auto-repeat and key-up included; a page action's key fires `action`): one that no `keydown` listener
/// prevented and that typed nothing. Space, the arrows, Page Up/Down, Home and End go to the player rather than
/// scroll the page. So a page calls `preventDefault()` on the keys it handles itself. While a text field, textarea,
/// select, contenteditable or a frame inside the page has the focus, no key goes to the player.
///
/// The panel holds one page: links to another origin, and anything the page opens in a new window, go to the default
/// browser. The page's alerts, confirms and prompts are shown as sheets. Only pages from `trusted` origins get the
/// bridge and are heard.
@MainActor final class PluginPanel: NSView, WKNavigationDelegate, WKUIDelegate {
    /// A request from the page and the origin it came from; malformed ones are answered here, ones from other
    /// origins never arrive.
    var onMessage: ((PluginRequest, PluginOrigin) -> Void)?
    /// The web view took or lost the keyboard.
    var onFocusChange: ((Bool) -> Void)?
    /// A page committed in the panel (a first load, a link, a reload) or its process died: what the old page declared
    /// is void. A navigation that is cancelled or fails leaves the old page, and its declarations, in place.
    var onPageReplaced: (() -> Void)?
    /// The user drags the panel's edge: the width it asks for, in points (not yet clamped).
    var onResize: ((CGFloat) -> Void)?
    /// A key-down the page left unhandled, for the player's keys, and whether its key is still held (WebKit answers
    /// after the page has seen the key, which can be after its key-up).
    var onUnhandledKey: ((NSEvent, _ stillDown: Bool) -> Void)?
    /// Every key-up in the web view, whatever the page did with it (a key-up never comes back from WebKit).
    var onKeyUp: ((NSEvent) -> Void)?

    /// The origins whose pages get `window.framescrub` (the next time a page loads) and whose messages are heard.
    var trusted: Set<PluginOrigin> = [] {
        didSet { if trusted != oldValue { installBridge() } }
    }

    private let webView: PanelWebView
    private let content = WKUserContentController()
    private let handler = MessageProxy()
    private let keyHandler = MessageProxy()
    private var keys = PluginKeyState()
    private let crashed = NSButton(title: "Reload", target: nil, action: nil)
    /// Why the page is not there (a failed load), above the Reload button.
    private let failure = NSTextField(wrappingLabelWithString: "")
    private(set) var url: URL?
    /// Whether the page was already reloaded once after its content process died: a second death shows the button.
    private var reloadedAfterCrash = false

    /// Guarded by the trusted origins, spelled as `location.protocol + "//" + location.host` is ("file://" for a
    /// local page): the page is the only one that could post, but a page outside the list is not given the bridge.
    private static func bridge(for origins: Set<PluginOrigin>) -> String {
        let list = origins.map { "\"\($0.description)\"" }.sorted().joined(separator: ", ")
        return "if ([\(list)].includes(location.protocol + \"//\" + location.host)) {\n\(bridge)\n}"
    }

    private static let bridge = """
    window.framescrub = {
      version: 1,
      _next: 1,
      _pending: {},
      _post(body) { window.webkit.messageHandlers.framescrub.postMessage(body); },
      send(cmd, args) { this._post(Object.assign({cmd}, args || {})); },
      request(cmd, args) {
        return new Promise((resolve, reject) => {
          const id = this._next++;
          this._pending[id] = {resolve, reject};
          this._post(Object.assign({cmd, id}, args || {}));
        });
      },
      _reply(id, result, error) {
        const p = this._pending[id];
        if (!p) return;
        delete this._pending[id];
        if (error == null) p.resolve(result == null ? undefined : JSON.parse(result));
        else p.reject(new Error(error));
      },
      _event(name, detail) {
        const handler = this["on" + name];
        if (handler) handler(detail);
        window.dispatchEvent(new CustomEvent("framescrub" + name, {detail}));
      },
      seek(t) { this.send("seek", {t}); },
      play() { this.send("play"); },
      pause() { this.send("pause"); },
      step(n) { this.send("step", {n}); },
      loop(a, b) { this.send("loop", a == null ? {} : {a, b}); },
      segments(list, opts) {
        const args = {segments: list};
        if (opts && opts.lock !== undefined) args.lock = opts.lock;
        if (opts && opts.advance !== undefined) args.advance = opts.advance;
        this.send("segments", args);
      },
      lock(on) { this.send("lock", {on}); },
      goSegment(i) { this.send("goSegment", {i}); },
      actions(list) { this.send("actions", {actions: list}); },
      open(o) { this.send("open", o); },
      focusPlayer() { this.send("focusPlayer"); },
      state: null,
      onstate: null,
      _state(s) { this.state = s; this._event("state", s); },
    };
    \(keyScript)
    """

    /// Keys for the player: before the page's listeners, whether its focus takes typing (sent when that changes); after
    /// them (a listener added to window while the event is still capturing runs after every page listener), a
    /// scrolling key nobody prevented is kept from scrolling and reported. Other keys come back from WebKit unhandled.
    private static let keyScript = """
    (() => {
      const post = body => window.webkit.messageHandlers.framescrubKeys.postMessage(body);
      const scrollKeys = [\(PluginKeyMessage.scrollKeys.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", "))];
      const plain = ["button", "checkbox", "color", "file", "image", "radio", "range", "reset", "submit"];
      const focused = () => {
        let el = document.activeElement;
        while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
        return el;
      };
      const typing = el => !!el && (el.isContentEditable || ["TEXTAREA", "SELECT", "IFRAME"].includes(el.tagName) ||
                                    (el.tagName === "INPUT" && !plain.includes(el.type)));
      let editing = false, last = null;
      const update = () => { if (typing(focused()) !== editing) { editing = !editing; post({editing}); } };
      window.addEventListener("focusin", update, true);
      window.addEventListener("blur", () => setTimeout(update), true);   // into a frame: its keys never come here
      window.addEventListener("keydown", e => {
        if (!e.isTrusted) return;
        update();
        const el = focused();
        if (last) window.removeEventListener("keydown", last);
        last = null;
        if (e.metaKey || e.isComposing || !scrollKeys.includes(e.code) || editing ||
            (el && ["INPUT", "BUTTON"].includes(el.tagName))) return;
        last = ev => {
          last = null;
          if (ev.defaultPrevented) return;
          ev.preventDefault();
          post({key: ev.code, shift: ev.shiftKey, control: ev.ctrlKey, option: ev.altKey, repeat: ev.repeat});
        };
        window.addEventListener("keydown", last, {once: true});
      }, true);
    })();
    """

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        content.add(handler, name: "framescrub")
        config.userContentController = content
        content.add(keyHandler, name: "framescrubKeys")
        let webView = PanelWebView(frame: .zero, configuration: config)
        self.webView = webView
        super.init(frame: frame)
        webView.onFocusChange = { [weak self] in
            self?.keys.focusMoved()
            self?.onFocusChange?($0)
        }
        webView.onPress = { [weak self] in self?.keys.pressed($0.keyCode) }
        webView.onRelease = { [weak self] in
            self?.keys.released($0.keyCode)
            self?.onKeyUp?($0)
        }
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        addSubview(webView)
        let edge = NSBox()
        edge.boxType = .custom
        edge.fillColor = NSColor(white: 1, alpha: 0.12)
        edge.borderWidth = 0
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        let splitter = SplitterView()
        splitter.translatesAutoresizingMaskIntoConstraints = false
        splitter.onDrag = { [weak self] width in self?.onResize?(width) }
        addSubview(splitter)
        crashed.target = self
        crashed.action = #selector(reloadPressed)
        crashed.bezelStyle = .rounded
        crashed.isHidden = true
        crashed.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crashed)
        failure.isHidden = true
        failure.alignment = .center
        failure.textColor = .secondaryLabelColor
        failure.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        failure.translatesAutoresizingMaskIntoConstraints = false
        addSubview(failure)
        NSLayoutConstraint.activate([
            failure.leadingAnchor.constraint(equalTo: webView.leadingAnchor, constant: 16),
            failure.trailingAnchor.constraint(equalTo: webView.trailingAnchor, constant: -16),
            failure.bottomAnchor.constraint(equalTo: crashed.topAnchor, constant: -12),
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            webView.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            crashed.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            crashed.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            splitter.leadingAnchor.constraint(equalTo: leadingAnchor),
            splitter.topAnchor.constraint(equalTo: topAnchor),
            splitter.bottomAnchor.constraint(equalTo: bottomAnchor),
            splitter.widthAnchor.constraint(equalToConstant: SplitterView.width),
        ])
        handler.receive = { [weak self] message in
            guard let self, let body = message.body as? [String: Any],
                  let origin = trustedOrigin(of: message.frameInfo) else { return }
            let id = PluginRequest.id(of: body)
            switch PluginMessage.parse(body) {
            case let .success(command): onMessage?(PluginRequest(id: id, message: command), origin)
            case let .failure(failure): fail(id: id, failure.reason)
            }
        }
        keyHandler.receive = { [weak self] message in
            guard let self, let body = message.body as? [String: Any], trustedOrigin(of: message.frameInfo) != nil,
                  let keyMessage = PluginKeyMessage.parse(body) else { return }
            keys.apply(keyMessage)
            if case let .key(key) = keyMessage { pageLetThrough(key) }
        }
    }

    // MARK: Keys the page leaves to the player

    /// WebKit sends a key-down the page did not handle (no listener prevented it, nothing typed or scrolled with it)
    /// back to the web view's `super.keyDown`, after the page has seen it; from there it climbs the responder chain to
    /// here. Taking it here also keeps the window from beeping at a key nobody wanted.
    override func keyDown(with event: NSEvent) {
        webView.keyCameBack()
        guard isTrusted(webView.url), keys.forwards(event.keyCode, isRepeat: event.isARepeat) else { return }
        onUnhandledKey?(event, keys.isDown(event.keyCode))
    }

    /// A scrolling key the page let through: the bridge kept it from scrolling the page, and it goes to the player as
    /// the key event it came from.
    private func pageLetThrough(_ key: PluginKey) {
        guard keys.forwards(key.keyCode, isRepeat: key.isRepeat) else { return }
        var flags: NSEvent.ModifierFlags = []
        if key.shift { flags.insert(.shift) }
        if key.control { flags.insert(.control) }
        if key.option { flags.insert(.option) }
        let characters = Self.scrollKeyCharacters[key.keyCode] ?? ""
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window?.windowNumber ?? 0, context: nil,
                                           characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: key.isRepeat, keyCode: key.keyCode) else { return }
        onUnhandledKey?(event, keys.isDown(key.keyCode))
    }

    private static let scrollKeyCharacters: [UInt16: String] = [
        49: " ", 123: function(NSLeftArrowFunctionKey), 124: function(NSRightArrowFunctionKey),
        125: function(NSDownArrowFunctionKey), 126: function(NSUpArrowFunctionKey),
        116: function(NSPageUpFunctionKey), 121: function(NSPageDownFunctionKey),
        115: function(NSHomeFunctionKey), 119: function(NSEndFunctionKey),
    ]

    private static func function(_ key: Int) -> String { UnicodeScalar(key).map { String(Character($0)) } ?? "" }

    /// Replaces the bridge script with one for the current trusted origins; pages already loaded keep theirs.
    private func installBridge() {
        content.removeAllUserScripts()
        guard !trusted.isEmpty else { return }
        content.addUserScript(WKUserScript(source: Self.bridge(for: trusted), injectionTime: .atDocumentStart,
                                           forMainFrameOnly: true))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows `url`: nothing happens when it is already the page, unless `force` asks for a reload. Refused (false)
    /// when the source may not load a page with that scheme.
    @discardableResult
    func load(_ url: URL, from source: PluginPageSource, force: Bool = false) -> Bool {
        guard source.accepts(url) else { return false }
        if url == self.url && !force { return true }
        self.url = url
        reloadedAfterCrash = false
        crashed.isHidden = true
        failure.isHidden = true
        webView.load(URLRequest(url: url))
        return true
    }

    /// Loads the page again from the server.
    func reload() {
        guard let url else { return }
        crashed.isHidden = true
        failure.isHidden = true
        webView.load(URLRequest(url: url))
    }

    @objc private func reloadPressed() { reload() }

    /// Sends the player's state to the page (no-op until the bridge exists). The JSON travels as an argument and is
    /// parsed in the page: splicing it into script source would break on U+2028 and U+2029.
    func push(_ state: PluginState) {
        guard !isHidden, let json = state.json else { return }
        call("if (window.framescrub) window.framescrub._state(JSON.parse(json))", ["json": json])
    }

    /// Answers a `request()`.
    func reply(_ reply: PluginReply) {
        call("if (window.framescrub) window.framescrub._reply(id, result, error)",
             ["id": reply.id, "result": reply.result as Any? ?? NSNull(), "error": reply.error as Any? ?? NSNull()])
    }

    /// Tells the page something happened.
    func dispatch(_ event: PluginEvent) {
        call("if (window.framescrub) window.framescrub._event(name, detail == null ? undefined : JSON.parse(detail))",
             ["name": event.name, "detail": event.detail as Any? ?? NSNull()])
    }

    /// A request failed: the page hears it as a rejection when it asked for a reply, else as an `error` event.
    func fail(id: Int?, _ reason: String) {
        if let id { reply(.failure(id, reason)) } else { dispatch(.error(reason)) }
    }

    /// Keys go to the page.
    func focus() {
        window?.makeFirstResponder(webView)
    }

    private func call(_ script: String, _ arguments: [String: Any]) {
        guard isTrusted(webView.url) else { return }
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { _ in }
    }

    // MARK: Which pages are heard

    /// The origin of a message's frame when it is the main frame of a trusted page; nil for frames inside the page,
    /// for a page the panel was redirected to, and for anything else.
    private func trustedOrigin(of frame: WKFrameInfo) -> PluginOrigin? {
        guard frame.isMainFrame, let origin = PluginOrigin(scheme: frame.securityOrigin.protocol,
                                                           host: frame.securityOrigin.host,
                                                           port: frame.securityOrigin.port),
              trusted.contains(origin) else { return nil }
        return origin
    }

    private func isTrusted(_ pageURL: URL?) -> Bool {
        pageURL.flatMap(PluginOrigin.init(url:)).map(trusted.contains) ?? false
    }

    // MARK: WKNavigationDelegate

    /// The panel stays on its page: a link to an origin that is not trusted opens in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame != false, let target = navigationAction.request.url else {
            decisionHandler(.allow)   // a frame inside the page loads what it likes
            return
        }
        if target.scheme?.lowercased() == "about" || isTrusted(target) {
            decisionHandler(.allow)
        } else {
            if ["http", "https"].contains(target.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(target) }
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        keys.pageReplaced()
        onPageReplaced?()
    }

    /// The page's web content process died: once, the page is simply loaded again; after that a button offers it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        keys.pageReplaced()
        onPageReplaced?()
        if reloadedAfterCrash {
            crashed.isHidden = false
        } else {
            reloadedAfterCrash = true
            reload()
        }
    }

    /// The page could not be loaded (no route, refused connection, App Transport Security…): the reason and a button.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showFailure(error)
    }

    private func showFailure(_ error: Error) {
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }   // a navigation replaced by another
        failure.stringValue = "\(url?.absoluteString ?? "")\n\(nsError.localizedDescription)"
        failure.isHidden = false
        crashed.isHidden = false
    }

    // MARK: WKUIDelegate

    /// `window.open` and links with a target: the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// As a sheet on the panel's window; modal when the panel has none.
    private func present(_ alert: NSAlert, then completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

/// The grab zone along the panel's leading edge: dragging it resizes the panel (it sits to the right of the video, so
/// a drag to the left widens it).
@MainActor private final class SplitterView: NSView {
    static let width: CGFloat = 6
    /// The width the drag asks for.
    var onDrag: ((CGFloat) -> Void)?
    private var startX: CGFloat = 0
    private var startWidth: CGFloat = 0

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        startWidth = superview?.frame.width ?? 0
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(startWidth + (startX - event.locationInWindow.x))
    }
}

/// Reports when the web view takes or gives back the keyboard, and the keys pressed in it.
@MainActor private final class PanelWebView: WKWebView {
    var onFocusChange: ((Bool) -> Void)?
    /// A key went down: its first sight, not WebKit sending back one the page left unhandled.
    var onPress: ((NSEvent) -> Void)?
    /// A key came up, whatever the page did with it.
    var onRelease: ((NSEvent) -> Void)?
    private var cameBack = false

    /// WebKit sends an unhandled key-down back through this method too; it then reaches the panel's `keyDown`
    /// (`keyCameBack`) before `super` returns.
    override func keyDown(with event: NSEvent) {
        let outer = cameBack
        cameBack = false
        super.keyDown(with: event)
        if !cameBack { onPress?(event) }
        cameBack = outer
    }

    func keyCameBack() { cameBack = true }

    override func keyUp(with event: NSEvent) {
        onRelease?(event)
        super.keyUp(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// WKUserContentController keeps its handlers strongly: a proxy keeps the panel out of that cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { receive?(message) }
    }
}
