import Foundation

/// The script that gives a plugin page `window.framescrub` (the bridge, documented in the app's `PluginPanel`).
public enum PluginBridgeScript {
    /// `framescrub.stash`: where the page finds Stash, and the key it needs.
    public struct StashAccess: Encodable, Equatable, Sendable {
        public var url: String
        public var apiKey: String

        public init(url: String, apiKey: String) {
            self.url = url
            self.apiKey = apiKey
        }
    }

    /// Guarded by the trusted origins, spelled as `location.protocol + "//" + location.host` is ("file://" for a
    /// local page): the page is the only one that could post, but a page outside the list is not given the bridge.
    /// `stash` is written into the page as JSON, for pages from `stashOrigins` only (the plugins the user listed, not a
    /// page a link brought); null for the others or without a server. `extra` runs inside the guard after the bridge.
    public static func source(trusted: Set<PluginOrigin>, stash: StashAccess?, stashOrigins: Set<PluginOrigin> = [],
                              extra: String = "") -> String {
        "if (\(originTest(trusted))) {\n\(bridge(stash: stashValue(stash, for: stashOrigins)))\n\(extra)\n}"
    }

    private static func originTest(_ origins: Set<PluginOrigin>) -> String {
        let list = origins.map { "\"\($0.description)\"" }.sorted().joined(separator: ", ")
        return "[\(list)].includes(location.protocol + \"//\" + location.host)"
    }

    private static func stashValue(_ stash: StashAccess?, for origins: Set<PluginOrigin>) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys   // slashes stay escaped: "</script>" cannot end anything
        guard !origins.isEmpty, let data = stash.flatMap({ try? encoder.encode($0) }),
              let json = String(data: data, encoding: .utf8) else { return "null" }
        return "(\(originTest(origins)) ? \(json) : null)"
    }

    private static func bridge(stash stashJSON: String) -> String {
        return """
        window.framescrub = {
          version: 2,
          stash: \(stashJSON),
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
          hide() { this.send("hide"); },
          playlist(items, opts) {
            const args = {items};
            if (opts && opts.index !== undefined) args.index = opts.index;
            if (opts && opts.name !== undefined) args.name = opts.name;
            this.send("setPlaylist", args);
          },
          enqueue(items) { this.send("enqueue", {items}); },
          state: null,
          onstate: null,
          _state(s) { this.state = s; this._event("state", s); },
        };
        """
    }
}
