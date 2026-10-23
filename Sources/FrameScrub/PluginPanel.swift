import AppKit
import FrameScrubCore
import WebKit

/// A web page beside the video: a plugin. The page drives the player through `window.framescrub` and hears the
/// player's state through it; the player knows nothing of what the page is for.
///
/// In the page:
///
///     framescrub.seek(seconds)        framescrub.play()          framescrub.pause()
///     framescrub.step(frames)         framescrub.loop(a, b)      framescrub.loop(null)
///     framescrub.open({path, t, seg: [a, b]})   or   framescrub.open({scene, paths, t, seg})   (a Stash scene)
///     framescrub.focusPlayer()        // keys go to the player again
///     framescrub.onstate = s => …     // {path, scene, t, frame, fps, duration, playing, loop: [a, b] | null, visible}
///
/// The panel holds one page: links to another origin, and anything the page opens in a new window, go to the default
/// browser. The page's alerts, confirms and prompts are shown as sheets. Only pages from `trusted` origins get the
/// bridge and are heard.
@MainActor final class PluginPanel: NSView, WKNavigationDelegate, WKUIDelegate {
    static let width: CGFloat = 400

    /// A command from the page and the origin it came from; malformed ones, and ones from other origins, never arrive.
    var onMessage: ((PluginMessage, PluginOrigin) -> Void)?

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
      send(cmd, args) { window.webkit.messageHandlers.framescrub.postMessage(Object.assign({cmd}, args || {})); },
      seek(t) { this.send("seek", {t}); },
      play() { this.send("play"); },
      pause() { this.send("pause"); },
      step(n) { this.send("step", {n}); },
      loop(a, b) { this.send("loop", a == null ? {} : {a, b}); },
      open(o) { this.send("open", o); },
      focusPlayer() { this.send("focusPlayer"); },
      state: null,
      onstate: null,
      _state(s) {
        this.state = s;
        if (this.onstate) this.onstate(s);
        window.dispatchEvent(new CustomEvent("framescrubstate", {detail: s}));
      },
    };
    """

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        content.add(handler, name: "framescrub")
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
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
        ])
        handler.receive = { [weak self] message in
            guard let self, let body = message.body as? [String: Any], let command = PluginMessage(json: body),
                  let origin = trustedOrigin(of: message.frameInfo) else { return }
            onMessage?(command, origin)
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
        guard !isHidden, let json = state.json, isTrusted(webView.url) else { return }
        webView.callAsyncJavaScript("if (window.framescrub) window.framescrub._state(JSON.parse(json))",
                                    arguments: ["json": json], in: nil, in: .page) { _ in }
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

/// WKUserContentController keeps its handlers strongly: a proxy keeps the panel out of that cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    var receive: ((WKScriptMessage) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { receive?(message) }
    }
}
