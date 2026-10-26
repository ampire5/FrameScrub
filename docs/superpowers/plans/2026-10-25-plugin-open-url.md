# Plugin pages open and list http(s) streams — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A trusted plugin page can `open({url})` an http(s) stream and put `{url, title?}` items in its playlist.

**Architecture:** The player already plays remote URLs (Stash's stream goes through `openFile` with an http URL). This
adds a `.stream` case to the bridge's `PluginOpen` and `PlaylistItem`, routes it to that path without the local-file
consent, and reports the URL in `fileopened` and `info`.

**Tech Stack:** Swift 6, Swift Testing, AppKit; SwiftPM (`scripts/test.sh`, `scripts/make-app.sh`).

**Spec:** `docs/superpowers/specs/2026-10-25-plugin-open-url-design.md`

## Global Constraints

- Only `http` and `https` with a non-empty host; anything else fails with exactly `url must be http(s)`.
- Exactly one of `path`, `scene`, `url` in `open` and in a playlist item; more than one fails with `give one of path, scene, url`.
- No request headers, cookies or user agent from the page; no resume position or Recent entry for a stream.
- `info.path` keeps its meaning (for a stream, its URL); `info.url` and `fileopened.url` are new; `fileopened.path` is `null` for any stream.
- Follow CLAUDE.md (main thread never blocks; no migrations or compatibility shims).
- Local development only: commit on `experiments`, never push.

## Review Focus

- A URL with spaces or non-ASCII in its path (`http://127.0.0.1:8793/stream/5367369?kind=trailer&q=best`, and one with `%20`) — opens unchanged, not re-encoded twice.
- A stream that answers 403/404 at open — `open` request rejects with `open: cannot open <url>`; in a list at autoadvance the next item is tried once and `error` fires.
- `enqueue` while a page stream is on screen with the folder as the playlist — the new list starts with that stream as a `.stream` item, not as a `.file` of an http URL.
- Stash's own stream keeps working after the `fileopened` change (`path: null`, `url` set, `scene` set).
- `file:///…` given as `url` — refused, never opened (a page must use `path` and the consent for local files).

---

### Task 1: Bridge messages and events (Core)

**Files:**
- Modify: `Sources/FrameScrubCore/PluginMessage.swift` (`PluginOpen`, `PluginOpen.init(_ args:)`, `PluginEvent.fileOpened`, `FileOpened`)
- Modify: `Sources/FrameScrubCore/ListPlaylist.swift` (`PlaylistItem`, `PlaylistRow`)
- Modify: `Sources/FrameScrubCore/PluginRequests.swift` (`PluginInfo`)
- Test: `Tests/FrameScrubCoreTests/PluginMessageTests.swift`, `Tests/FrameScrubCoreTests/ListPlaylistTests.swift`, `Tests/FrameScrubCoreTests/PluginRequestsTests.swift`

**Interfaces:**
- Produces:
  - `PluginOpen.stream(URL, landing: LinkTarget)`; `landing` covers it.
  - `PlaylistItem.stream(URL, title: String?)`; `title` covers it.
  - `Arguments.streamURL(_ key: String) throws(Failure) -> URL` (http/https with host, else `url must be http(s)`).
  - `PluginEvent.fileOpened(path: String?, url: String?, scene: String?, source: PluginSource)`.
  - `PluginInfo.url: String?` (init parameter `url: String? = nil`).
  - `PlaylistRow(item)` for `.stream`: the given title, else the URL's last path component, else the host.

- [ ] **Step 1: Write the failing tests**

In `PluginMessageTests`:

```swift
@Test func openStream() {
    #expect(message(["cmd": "open", "url": "http://127.0.0.1:8793/stream/5?kind=trailer", "t": 3])
            == .open(.stream(URL(string: "http://127.0.0.1:8793/stream/5?kind=trailer")!,
                             landing: LinkTarget(time: 3, segments: [], lock: nil, advance: nil))))
    #expect(message(["cmd": "open", "url": "https://cdn.example/a%20b.mp4"]) != nil)
    for bad in ["file:///v/a.mp4", "ftp://h/a.mp4", "/v/a.mp4", "http://", "http:///a.mp4", ""] {
        #expect(message(["cmd": "open", "url": bad]) == nil, "\(bad)")
    }
    #expect(message(["cmd": "open", "url": "http://h/a.mp4", "path": "/v/a.mp4"]) == nil)
    #expect(message(["cmd": "open", "url": "http://h/a.mp4", "scene": 3]) == nil)
}

@Test func playlistStreamItems() {
    let json = posted(#"{"cmd":"setPlaylist","items":[{"url":"http://h/s/1","title":"A"},{"scene":2}]}"#)
    #expect(message(json) == .setPlaylist(items: [.stream(URL(string: "http://h/s/1")!, title: "A"),
                                                 .scene(id: "2", title: nil)], index: 0, name: nil))
    #expect(message(posted(#"{"cmd":"enqueue","items":[{"url":"file:///a.mp4"}]}"#)) == nil)
}

@Test func fileOpenedForAStream() {
    #expect(PluginEvent.fileOpened(path: nil, url: "http://h/s/1", scene: nil, source: .stream).detail
            == #"{"path":null,"scene":null,"source":"stream","url":"http:\/\/h\/s\/1"}"#)
}
```

Update the existing `fileOpened` expectations (around lines 207–211) to the new case with `url: nil` for a file, and
for Stash's stream `path: nil, url: "<stream url>"`. Match the encoder's key order as the existing tests do. Where a
failure reason is checked, the message for a bad URL is `url must be http(s)` and for two keys `give one of path, scene, url`.

In `ListPlaylistTests`: `enqueue([.stream(u, title: nil)], onto: nil, current: .stream(v, title: "B"))` gives a list
`[.stream(v, "B"), .stream(u, nil)]` with index 0; `PlaylistRow(.stream(URL(string: "http://h/x/trailer.mp4")!, title: nil)).title == "trailer.mp4"`,
with `title: "T"` → `"T"`, for `http://h/` → `"h"`.

In `PluginRequestsTests`: `PluginInfo(…, url: "http://h/s/1")` encodes `"url":"http:\/\/h\/s\/1"`; without it `"url":null`.

- [ ] **Step 2: Run the tests to see them fail**

Run: `swift test --filter 'PluginMessageTests|ListPlaylistTests|PluginRequestsTests'`
Expected: compile errors for `.stream`, `url:`.

- [ ] **Step 3: Implement**

`PluginOpen.init` and `PlaylistItem.init(_ args:)` count which of `path`, `scene`, `url` are present; more than one throws
`give one of path, scene, url`; none keeps today's messages (`path or scene is missing` → `path, scene or url is missing`;
`needs scene or path` → `needs scene, path or url`). `streamURL` uses `URL(string:)`, `scheme` in `["http", "https"]`
(lowercased) and a non-empty `host`. Update doc comments on `PluginOpen`, `PlaylistItem`, `PluginInfo.source`.

- [ ] **Step 4: Run the tests to see them pass**

Run: `swift test --filter 'PluginMessageTests|ListPlaylistTests|PluginRequestsTests'`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FrameScrubCore Tests/FrameScrubCoreTests
git commit -m "Plugin bridge: open and list http(s) streams (messages, items, fileopened and info url)"
```

### Task 2: Player wiring, docs, check in the app

**Files:**
- Modify: `Sources/FrameScrub/PlayerWindowController.swift` (plugin command switch near `case let .open(.file(url, landing))` ~line 2711; `openListItem` ~line 2250; `currentPlaylistItem` ~line 2266; `fileOpened` dispatch ~line 2881; the `info` answer)
- Modify: `README.md` (Plugins › bridge tables, Playlists from a page)

**Interfaces:**
- Consumes: everything Task 1 produces.

- [ ] **Step 1: Wire `open(.stream)`**

New case next to `.open(.file…)`: `page.map(slots.pageChosePlay)`, `dropListPlaylist()`, then
`open(OpenLink.Target(file: url, landing: landing))` → `pluginDone(request)` or `pluginFailed(request, "open: cannot open \(url.absoluteString)")`.
No `pluginPolicy` decision (nothing local). Check that `open(OpenLink.Target…)` reaches `openFile` for a remote URL
without the folder/Recent work, as Stash's stream does; if it insists on a file, call the same path `openStashScene`
uses (`openFile(url, origin:…)`) with the landing applied.

- [ ] **Step 2: Wire list items**

`openListItem`: `case let .stream(url, _)` behaves like `.file` (reset `stashScene`, bump `stashOpens`, cancel the
queue gate, `openFile(url)`, `failed()` on false). `whenListAllowed` already asks only about `.file` items.
`currentPlaylistItem`: a remote `core.url` (`ByteSources.isRemote`) with a non-Stash origin is `.stream(url, title: window?.title)`.

- [ ] **Step 3: `fileopened` and `info`**

`fileopened`: for a remote `core.url`, `path: nil, url: absoluteString`; for a file, `path: core.url?.path, url: nil`.
`info`: set `url` for a remote file; `path` unchanged.

- [ ] **Step 4: README**

In the verbs table: `open(o)` names `{url}`; in "Playlists from a page": items `{scene, title?} | {path, title?} | {url, title?}`;
in the events table: `fileopened` `{path, url, scene, source}`; in the `info` row: `url`. One sentence under
"Segments and opening files": an `http(s)` `url` plays as a stream, no consent asked; headers and cookies are not passed,
so a page that needs them serves the stream itself.

- [ ] **Step 5: Full suite**

Run: `scripts/test.sh`
Expected: all pass (≈1395+ tests, 0 failed).

- [ ] **Step 6: Check in the app**

`scripts/make-fixtures.sh` output (or any short mp4) served with `python3 -m http.server 8799` from its folder, plus a
test page `check.html` in the same folder:

```html
<!doctype html><button id=a>open</button><button id=b>list</button><script>
const fs = window.framescrub, u = n => `http://127.0.0.1:8799/${n}`;
fs.onfileopened = d => document.title = JSON.stringify(d);
a.onclick = () => fs.request("open", {url: u("<fixture>.mp4"), t: 2}).then(() => fs.request("info")).then(i => document.title += " " + i.url);
b.onclick = () => fs.playlist([{url: u("<fixture>.mp4"), title: "one"}, {url: u("missing.mp4")}, {url: u("<fixture>.mp4"), title: "three"}]);
</script>
```

Add `plugin=Check | http://127.0.0.1:8799/check.html` to `~/.config/framescrub/framescrub.conf`, build and install
(`scripts/make-app.sh --install`), show the page in a slot. Expected: "open" plays the fixture from 2 s, the title shows
`"path":null`, the URL and `"source":"stream"`; "list" plays "one", next skips the missing item once with an `error`,
"three" plays. Remove the `plugin=Check` line afterwards.

- [ ] **Step 7: Commit**

```bash
git add Sources/FrameScrub README.md
git commit -m "Plugin pages play http(s) streams: open({url}), {url} playlist items"
```
