# Playlist strip: the playlist as a vertical filmstrip in its slot

Date: 2026-10-27. Status: design, not implemented. Branch: `strip-slots` (FrameScrub, HomeScreenKit; Loupe for its
regression only). Stage F1 of the filmstrip plan (artifact «Лента во FrameScrub», 2026-10-22).

## Problem

The playlist in its slot is an `NSTableView` of names (`PlaylistPanelView`). It shows nothing of what a file is: no
picture, no length, no format, no position. Loupe's filmstrip (HomeScreenKit `FilmstripModel` / `Filmstrip`) shows a
folder as pictures under a fixed centre; the mockup turns the same idea into a vertical playlist: a whole frame per
video, the row at the centre larger with a card, the position as a bar on the picture.

## Goals

1. With `playlist-view = strip` the playlist slot shows a vertical strip instead of the table; `list` (the default)
   keeps today's table. The filter field and the order menu stay above either.
2. Scrolling browses: the row at the centre (the *browsed* row) grows and shows its card; the video does not change.
   A click or ↩ opens a row. Left alone, the strip goes back to the playing video.
3. Each row: the picture (last seen frame, else Home's poster, else an empty frame), the name, one line of facts,
   the position as a bar on the picture; the playing video is marked.
4. The strip is HomeScreenKit's: a vertical axis and a row layout that Loupe's folder strip (L4) can use as is.
5. Within the budgets of `CLAUDE.md`, measured by a bench; Loupe's horizontal strip unchanged.

Not in scope: the capsule with pin and chevron from the mockup (the slot's header already has pin / float, backdrop
and hide), audio and subtitle tracks and the bitrate graph on the card (not in `FileFacts`; stage F5, SQLite), the
timeline (F2–F4), a shared playlist model (stage 5), moving slots into the kit (stage 3).

## Behaviour

### Browsed and playing

Two indices: `playing` (the open video, from the playlist) and `browsed` (the row at the centre). The strip lays out
and scrolls around `browsed`; `playing` only draws a marker (an accent edge on its picture and «▶» before its name).

- Opening a video (any way: the strip, the keys, autoadvance) sets both to it; the strip slides there unless the
  user is in a gesture.
- Scrolling (trackpad, wheel, drag) moves the strip under its centre; the row that reaches the centre becomes
  `browsed` (`FilmstripScroll.Outcome.item`). Nothing is opened, not on the settle either.
- A click on a row opens it. A click on the browsed row's card opens it too.
- **Return.** After `playlist-strip-return` seconds (default 3, 0 = never) with no gesture, no pointer over the
  strip and no typing in the filter, `browsed` goes back to `playing` with the strip's settle animation. One
  one-shot timer, re-armed on each of those events, cancelled when the slot hides or the window is not visible.

### Keys

Keys stay with the video as today (the strip, like the table, refuses first responder). With the filter field
active (⌘F, or F8 / Tab with the slot shown, as now): ↑ / ↓ move `browsed` by one row, ⇞ / ⇟ by a screenful,
↩ opens `browsed` (today: the first row shown), Esc as today. Typing in the filter keeps `browsed` on the same file
when it stays in the list, else on the first row.

### Scroll ownership

A scroll event over the slot never reaches the video: the video's ⌘+scroll zoom and its pan must not fire under the
strip. A horizontal swipe over the vertical strip does nothing (the slot does not move the window either).

### Filter and order

Unchanged: the strip shows `Playlist`'s filtered, ordered rows. When the rows change (filter, order, the folder
watcher adding a file), the strip keeps `browsed` on its file with `FilmstripItems.indexMap`, as Loupe does.

## Row content

| Part | Source | Cost |
|---|---|---|
| Picture | `ThumbnailStore` (last frame seen); else the poster Home made (`RecentThumbnailer`, `KeyframeThumbnail`); else an empty frame | a JPEG read off the main thread; a poster is made only on dwell (below) |
| Aspect | `FileFacts` (`FileFactsStore`); unknown: 16:9 | a dictionary lookup |
| Name | the file name without extension, middle-truncated | free |
| Facts line | length · resolution class · codec (`2:14:05 · 4K · HEVC`); without facts: the size | lookup |
| Position | `ResumeStore.entry` position ÷ length: the bar along the picture's bottom edge; none for an unplayed file | lookup |
| Card (browsed row) | the name on up to two lines; size and date; width × height, codec, frame rate; watched share | lookups, built only for the browsed row |

**Posters on dwell.** A row that has stayed in the visible window for 0.3 s and has no picture asks for a poster.
The requests go to a `RecentThumbnailer` of its own with Home's worker counts (`RecentThumbnailer.localWorkers` on
this Mac's disks, one on a share), `.utility`. Rows that left the window before their turn are dropped from the
queue; at most a screenful (≤ 24) is queued. A poster made here is saved where Home's are, with its `FileFacts`, so
Home and the strip share them.

## Architecture

### HomeScreenKit (`strip-slots`)

**`FilmstripModel`**

- `FilmstripAxis` gains `.vertical`. The model already names its dimensions *along* and *across*.
- `FilmstripTrack` (new protocol): what `FilmstripScroll` reads of a layout — `itemCount`, `offsetRange`,
  `centre(of:)`, `item(atBase:)`. `FilmstripLayout` conforms; `FilmstripScroll`'s `layout:` parameters take
  `some FilmstripTrack`. Source compatible for Loupe.
- `FilmstripScroll` takes the deltas along the strip's axis: for `.vertical` the vertical swipe moves, the
  horizontal one does nothing; the axis lock, momentum, rest and rubber band are unchanged.
- `FilmstripRows` (new, pure, tested): the row layout. Input: axis, item count, aspects (width ÷ height per item,
  nil = unknown), the strip's length (along) and width (across), `rowPicture` (the across size of a plain row's
  picture, e.g. 96 pt), `currentPicture` (the browsed row's, e.g. the strip's width minus padding), the gap, the
  expansion (0…1, animated as Loupe's). Every picture is whole, scaled to its across size; a plain row's along size
  is its picture's (portrait pictures are capped at a 1:1 box so one tall file does not take the screen); the
  browsed row's is its picture's plus the card's height (`cardHeight`, given by the owner). Output: the visible
  cells (item, along start and length, picture rect within the row), `centre(of:)`, `item(atBase:)`,
  `offsetRange`, and the fades (only where the strip goes on, never over the browsed row).

**`Filmstrip`**

- `FilmstripRowsView` (new): the vertical strip view on `FilmstripRows`, with the same layer pool, edge fade and
  input handling as `FilmstripView` (press, drag, scroll routing, `acceptsMouse`). Per row: the picture layer, a
  position bar, a playing marker, and two text lines; for the browsed row a card view supplied by the owner.
  API as `FilmstripView`'s where it applies (`show(offset:current:expansion:animated:)`, `setImage`,
  `setUnavailable`, `forget`, `remap`, `visibleItems`, `onPress`, `onDrag`, `onStripScroll`, `routeScroll`)
  plus `setRow(_ item: Int, title: String, detail: String, progress: Double?)`, `playing: Int?` and
  `card: NSView?` (placed beside or under the browsed picture; the view asks for its fitting height).
- Shared code between the two views (the pool, the fade mask, press tracking) moves into internal helpers rather
  than being copied. `FilmstripView` itself stays horizontal: making it axis-generic would touch ~30 places that
  Loupe's behaviour depends on, for no use here.
- `homescreen-demo` gains a vertical rows strip.

**Loupe.** No source change expected. Its tests and `StripBench` must pass against the branch.

### FrameScrub (`strip-slots`)

- `Config`: `playlist-view` (`list` | `strip`, default `list`) and `playlist-strip-return` (0…30 s, default 3),
  each with a row and description on the page that has `playlist-font-size` (`PageHomeInterface`) (the coverage test lists every key).
- `PlaylistPanelView` stays the slot's content and `SlotsController` does not change. Under the filter bar it holds
  either the table or a `PlaylistStripView` (new, AppKit glue), swapped when `playlist-view` changes. Its public API
  (`onSelect`, `beginFilter`, `isEditingFilter`, the rows, the selection) is served by whichever is shown.
- `PlaylistStripView` owns a `FilmstripRowsView` and a `FilmstripScroll`; it keeps `playing` and `browsed`, the
  return timer, and the dwell queue; it builds the card for the browsed row.
- `PlaylistRowFacts` (FrameScrubCore, pure, tested): from a URL, `FileFacts?`, `ResumeEntry?` and the file's size
  and date, the facts line, the card's lines and the progress. No AppKit.
- `PlaylistPosters` (FrameScrubCore): the dwell queue in front of a `RecentThumbnailer` — `visible(_ urls:)`,
  `cancelAll()`, a completion on the main actor with the picture and the facts.

### Decided in the plan

- No `FilmstripAxis.vertical`: `FilmstripScroll` is axis-free already (`fingerDelta` along the strip, `crossDelta`
  across); the vertical view passes the vertical delta as `fingerDelta`. Only `FilmstripTrack` is added.
- `FilmstripView` and `FilmstripRowsView` share only the edge fade (`FilmstripFade`); what a cell holds differs, so
  each keeps its own pool.
- Posters: Home's `PictureQueue` moves to its own file and is reused on the `posters` store, with the strip's own
  one-worker `RecentThumbnailer`.
- `PlaylistRow` gains `url: URL?` (the local file; nil for scenes and streams) so the strip can find pictures.

## Budgets and bench

`FrameScrubBench playlist-strip` on a generated folder of 500 videos (copies of the test fixtures, files of 3
aspects), the real window and slot, main-thread CPU (`CLOCK_THREAD_CPUTIME_ID`), 5 rounds:

| Action | Budget |
|---|---|
| Show the slot with the strip, first time / again | ≤ 100 ms / ≤ 30 ms |
| One scroll event (trackpad, continuous) | ≤ 8 ms, p99 |
| `browsed` moves by one (card rebuilt) | ≤ 16 ms |
| Filter text changes (500 → 40 rows) | ≤ 50 ms |

Rounds that get slower mean something accumulates. The table goes into `docs/bench/2026-10-27-playlist-strip.md`
with the machine; budgets are checked on an Intel Mac before the strip becomes the default (not in this stage).
At rest (no gesture, no pending poster, return timer fired or cancelled) the strip does no work.

## Testing

- `FilmstripRowsTests`: whole pictures at every aspect, the browsed row's size with and without a card, centre and
  `item(atBase:)` round trip, offset range at 0 / 1 / many items, fades never over the browsed row, portrait cap.
- `FilmstripScrollTests`: the existing ones unchanged; vertical axis: vertical deltas move, horizontal do nothing;
  `FilmstripRows` as the track.
- `PlaylistRowFactsTests`: facts line with and without facts, progress for played / unplayed / finished files.
- `PlaylistPostersTests`: dwell, the cap, rows that leave the window are dropped, nothing queued at rest.
- By hand on the installed build (only when the user says to install from this branch): browse, open by click and
  ↩, return after 3 s, filter and order, a share folder, the slot pinned and overlay, full screen.

## Risks

- **Two views, one pool.** Factoring the pool and fade out of `FilmstripView` could change Loupe's strip. Mitigation:
  extract by moving code without changing it, Loupe's tests and bench before and after.
- **Card height inside the layout.** The browsed row's size depends on the card's fitting height; the card is
  measured once per `browsed` change, never per frame.
- **Posters on a share** compete with playback; one worker and the dwell keep it to what is looked at.
