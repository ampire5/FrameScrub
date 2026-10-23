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
///     framescrub.onstate = s => …     // {path, scene, t, frame, fps, duration, playing, loop: [a, b] | null}
@MainActor final class PluginPanel: NSView {
    static let width: CGFloat = 400

    /// A command from the page; malformed ones never arrive.
    var onMessage: ((PluginMessage) -> Void)?

    private let webView: WKWebView
    private let handler = MessageProxy()
    private(set) var url: URL?

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
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(handler, name: "framescrub")
        config.userContentController = content
        webView = WKWebView(frame: .zero, configuration: config)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        let edge = NSBox()
        edge.boxType = .custom
        edge.fillColor = NSColor(white: 1, alpha: 0.12)
        edge.borderWidth = 0
        edge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(edge)
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: leadingAnchor),
            edge.topAnchor.constraint(equalTo: topAnchor),
            edge.bottomAnchor.constraint(equalTo: bottomAnchor),
            edge.widthAnchor.constraint(equalToConstant: 1),
            webView.leadingAnchor.constraint(equalTo: edge.trailingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        handler.receive = { [weak self] body in
            guard let body = body as? [String: Any], let message = PluginMessage(json: body) else { return }
            self?.onMessage?(message)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func load(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        webView.load(URLRequest(url: url))
    }

    /// Sends the player's state to the page (no-op until the bridge exists).
    func push(_ state: PluginState) {
        guard !isHidden, let json = state.json else { return }
        webView.evaluateJavaScript("window.framescrub && window.framescrub._state(\(json))")
    }
}

/// WKUserContentController keeps its handlers strongly: a proxy keeps the panel out of that cycle.
private final class MessageProxy: NSObject, WKScriptMessageHandler {
    var receive: ((Any) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { receive?(message.body) }
    }
}
