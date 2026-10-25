# Plugin bridge: open and list HTTP streams

Date: 2026-10-25. Status: design agreed, awaiting review.

## Goal

A plugin page can play a video that is not a local file or a Stash scene: an `http(s)` URL, typically served by the
page's own backend. Today `open` takes `{path}` or `{scene}`, and playlist items take `{path}` or `{scene}`; the player
already plays HTTP streams (Stash's stream goes through `openFile` with a remote URL), so this only opens that path to
pages.

Out of scope: request headers, cookies or a user agent from the page (a page that needs them serves the stream through
its own backend), other URL schemes, resume positions for streams.

## Bridge

- `open({url, t?, segments?, lock?, advance?})`: `url` is an absolute `http` or `https` URL with a host. Anything else
  fails with `url must be http(s)`. No consent is asked: nothing local is read. Exactly one of `path`, `scene`, `url`.
- `playlist(items)` / `enqueue(items)`: an item may be `{url, title?}`, validated the same way; one bad item refuses the
  whole call as today.
- `fileopened` and `info`: `source` is `"stream"` (as for Stash's stream), `path` is `null`, and a new `url` field
  carries the URL. `state.path` stays `null` for a stream; `state.name` is the item's `title`, else the URL's last path
  component.

## Player

- `PluginOpen` gains `.stream(URL, landing: LinkTarget)`; `ListPlaylist` items gain `.url(URL, title:)`.
- Opening goes through the same `openFile` path as Stash's stream: no folder, no file facts, no place in Recent, no
  resume position. Landing (`t`, segments, lock, advance) applies as for a file.
- A list item that cannot be opened fires `error` and, at autoadvance, the next item is tried once, as for scenes.
- Trust is unchanged: only pages from configured origins are heard.

## Docs and tests

- README › Plugins: `open` and playlist items with `url`, the `url` field of `fileopened` and `info`.
- Tests: `PluginMessage` parsing (`url` accepted for http/https, refused for `file:`, `ftp:`, relative, missing host;
  `url` with `path` or `scene` refused), `ListPlaylist` items with `url`, the `fileopened` payload for a stream.
