import AppKit
import FrameScrubCore
import WebKit

/// A web page beside the video: a plugin. The page drives the player through `window.framescrub` and hears the
/// player's state through it; the player knows nothing of what the page is for.
///
/// The bridge, version 1 (`framescrub.version`):
///
/// Commands. Each verb posts a command and forgets it; `request(cmd, args)` posts the same command and returns a
/// Promise that resolves with the command's result (undefined for the verbs below) or rejects with an Error whose
/// message says what was wrong (unknown command, missing or mistyped argument, a refused open).
///
///     framescrub.seek(t)              seek to `t` seconds (not negative)
///     framescrub.play()  .pause()
///     framescrub.step(n)              `n` frames forward, negative backward
///     framescrub.loop(a, b)           an A-B loop in seconds, `b` above `a`;  loop(null) clears it
///     framescrub.open(o)              o = {path, t?, seg?: [a, b]} a local video (absolute path; the first time a page's
///                                     origin asks, the user is asked to allow it), or {scene, paths, t?, seg?} a Stash
///                                     scene found on the shares
///     framescrub.focusPlayer()        keys go to the player again (the page's Esc, usually)
///     framescrub.request(cmd, args)   any of the above by name, with a reply: request("seek", {t: 12})
///
/// State. `framescrub.state` is the latest state; `framescrub.onstate = s => …` and the window event "framescrubstate"
/// (`event.detail`) hear each change, at most ten times a second while frames show:
///
///     {ready, path, name, scene, t, frame, fps, duration, durationFrames, playing, loop: [a, b] | null, visible}
///
/// Events. `framescrub.on<name> = detail => …`, or the window event "framescrub<name>" with `event.detail`:
///
///     focus / blur                    the panel took the keyboard / gave it back (View › Focus Plugin Panel, ⌃⌥⌘P,
///                                     brings keys to the page; focusPlayer() returns them)
///     fileopened                      {path, scene} once a file is open, however it was opened
///     error                           a reason string, when a verb (sent without a reply) failed
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
    /// The user drags the panel's edge: the width it asks for, in points (not yet clamped).
    var onResize: ((CGFloat) -> Void)?

    /// The origins whose pages get `window.framescrub` (the next time a page loads) and whose messages are heard.
    var trusted: Set<PluginOrigin> = [] {
        didSet { if trusted != oldValue { installBridge() } }
    }

    private let webView: WKWebView
    private let content = WKUserContentController()
    private let handler = MessageProxy()
    private let crashed = NSButton(title: "Reload", target: nil, action: nil)
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
      open(o) { this.send("open", o); },
      focusPlayer() { this.send("focusPlayer"); },
      state: null,
      onstate: null,
      _state(s) { this.state = s; this._event("state", s); },
    };
    """

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        content.add(handler, name: "framescrub")
        config.userContentController = content
        let webView = PanelWebView(frame: .zero, configuration: config)
        self.webView = webView
        super.init(frame: frame)
        webView.onFocusChange = { [weak self] in self?.onFocusChange?($0) }
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
        NSLayoutConstraint.activate([
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
    }

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
        webView.load(URLRequest(url: url))
        return true
    }

    /// Loads the page again from the server.
    func reload() {
        guard let url else { return }
        crashed.isHidden = true
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

    /// The page's web content process died: once, the page is simply loaded again; after that a button offers it.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if reloadedAfterCrash {
            crashed.isHidden = false
        } else {
            reloadedAfterCrash = true
            reload()
        }
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

/// Reports when the web view takes or gives back the keyboard.
private final class PanelWebView: WKWebView {
    var onFocusChange: ((Bool) -> Void)?

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
