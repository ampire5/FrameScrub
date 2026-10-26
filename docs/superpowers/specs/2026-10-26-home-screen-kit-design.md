# Home: HomeScreenKit's HomeView in FrameScrub

Date: 2026-10-26. Status: design, not implemented.

## Problem

FrameScrub's start screen is HomeScreenKit 0.1.0's `HomeScreenView`: Recent as a grid of cards and, with Stash set
up, a second tab holding `StashLibraryView`. It shows only when nothing is open, has no folders, no sidebar, no
history, and the README already marks it as "FrameScrub's start screen until it moves to `HomeView`". Loupe is on
`HomeView` and the kit is at 0.5.0 (NSToolbar, sidebar tree, sessions, card styles, the thumbs pill).

The ROADMAP asks for "a Photos-style start screen with a sidebar, Recent and Stash", the same one Loupe has.

## What Loupe does (reference, Loupe `main`)

- Home lives in the viewer window. It is built lazily once per window, added once, then only hidden and "parked"
  (`isParked`). Adding and removing the view cost 25 ms each way.
- Showing Home swaps `window.toolbar` to `browser.nsToolbar`, gives the window a transparent titlebar and unpauses
  the folder source. Hiding it does the reverse.
- One `HomeSource` conformance (`LoupeHomeSource`, 147 lines) dispatches to two classes:
  - `FolderBrowserSource` handles Places, folders, menus, rename, trash, sort and thumbnails.
  - `CollectionSource` handles Recent, Sessions, and Stash as an app page.
- Everything except the view is Loupe's: listing, thumbnails, sort memory and file actions. Thumbnails take at most
  2 reads at a time, decode at `.utility` QoS on half the physical cores minus one (1…4), and wait 100 ms after the
  viewer's work.
- About 2.3k lines of glue in the app and 2–3.5k in core, most of it in thumbnails, covers and the thumbs walk.
  FrameScrub needs a much smaller first cut.

## Goals

1. Home = `HomeView` in the player window. Its sidebar has:
   - **Recent**: an app source, grouped by date, showing each video's resume progress;
   - **Places and folders**: videos only;
   - **Stash**: an app page holding the existing `StashLibraryView`;
   - **Playlist**: an app source for a page's `ListPlaylist`, when there is one.
2. Opening from Home behaves like opening a file now: resume, the folder playlist, the Stash scene. Home's sort for
   that folder becomes the playlist's order, so › and ‹ step through what the grid showed.
3. Returning to Home (⇧⌘H, ⌘[, Esc on a paused video, the mouse's Back button where the profile says so) shows the
   folder the video came from, with the video selected. Nothing is rebuilt.
4. Video thumbnails (poster frames) for folder cards, within the rules of `CLAUDE.md`.

## Non-goals (first cut)

- Several windows or tabs: FrameScrub stays single-window (`supportsTabs = false`). `HomeClick` modifiers open
  "here".
- Folder covers (mosaics of the videos inside), the thumbs-ahead walk, the progress pill, Sessions, card facts.
  These are Loupe's heavy parts; they come later if wanted.
- Migrations: `home-layout` is dropped like the older slot keys were (no migration, as for slots).

## Design

### Window

- `PlayerWindowController` replaces `startScreen: HomeScreenView` with `home: HomeView`. It is made on first show
  and then kept: hidden and `isParked`, never removed.
- Layering stays as it is today. Home sits over `videoView`, and the slots (`SlotsController(container:above:)`) sit
  above Home. A plugin page in a slot keeps working on Home, and its action keys still reach it.
- **Showing Home:**
  - pauses the video and keeps the file open, so going back to the video costs nothing;
  - swaps the window's toolbar to `home.browser.nsToolbar` and hides the seek bar, HUD and OSD;
  - turns the precision wheel off.
- **Hiding Home** restores everything. The window title comes from `onWindowText` while Home shows.
- With nothing open, Home is what the window shows (today's start screen). The `failedURL` / `failedScene` message
  goes to the browser's `showToast` (one line), with the full reason in the OSD as today. `HomeScreenView`'s
  message view is not ported.
- **Keys:**
  - ⇧⌘H shows Home; on Home it goes to Recent.
  - ⌃⌘S toggles the sidebar.
  - ⌘[ / ⌘] are the browser's history while Home shows. On a video, ⌘[ returns to Home.
  - ⌘= / ⌘− / ⌘0 change the card size (`onResize`, saved as `home-card-size`).
  - Everything else goes through `handleKey` before the player's own keys, as `startScreen.handleKey` does now.
- **Mouse:** `SideButtonFilter.startScreenPress` becomes a Home case. Back / Forward move through the browser's
  history (`onOtherMouse`), and the Viewing / Editing profiles decide only what they do over a video.

### Source

`FrameScrubHomeSource` (app target) is the one `HomeSource` conformance. It dispatches to the following parts.

| Part | Where | Does |
|---|---|---|
| `VideoFolderSource` | app | Places, `list(.folder)`, `folders(in:)`, `parent`, menus, rename, trash, `open` |
| `VideoListing` | Core | listing on a detached `.userInitiated` task: names first, then attributes; `Playlist.videoExtensions` + folders |
| `RecentSource` | app | `.source("recent")`: `RecentFiles` + `HiddenRecent` + `ResumeStore` → entries with `progress`, `subtitle` = time text, date groups |
| `PlaylistSource` | app | `.source("playlist")`: the current `ListPlaylist` (files, scenes, streams) with its `t:` and `info` titles |
| Stash | app | `.source("stash")`: `HomeSourceInfo(page: StashLibraryView)`, made lazily as `makeStashLibrary()` does now |

- `VideoListing` reuses `FolderListing.read`, so the Home grid and the playlist read a folder once. The listing is
  kept, and `open` hands it to `Playlist(current:sort:listing:)`. Today a folder open on SMB reads the folder a
  second time.
- `BrowserSort` ↔ `PlaylistSort`:
  - Name / Date / Size map one to one.
  - The kit's reversed sorts have no playlist counterpart yet; `PlaylistSort` gains a `reversed` flag.
  - The sort is kept per folder in `ResumeStore`'s directory as `home-sorts.json`, bounded to 500 folders, LRU.
    `playlist-sort` stays the default for folders without one.
- File actions: rename and trash go through `FileRemoval` (it already trashes where the volume has a Trash and asks before deleting for good on SMB). The
  menus are Show in Finder, Copy Path, Open in New Window (later), and Remove from Recent (Recent only).
- `RecentFiles.shown`'s limit of 10 becomes `recent-count` (default 50). Recent is a list with date groups, no longer
  a fit-to-window grid.

### Thumbnails (poster frames)

This is the expensive part. A poster frame means opening a file, demuxing it and decoding a keyframe. On a NAS that
is several ranged reads per file, and it competes with the video being played.

- `PosterStore` (Core) generalises `ThumbnailStore`:
  - **Recent** keeps today's picture of the last frame seen (`ThumbnailStore`, unchanged).
  - **Folders** get a keyframe near 10% of the duration (`KeyframeThumbnail.make(url:at:)`, capped to the first
    keyframe after 10 s). It is saved as a 480 px JPEG in `thumbnails/posters/`, keyed like `ResumeStore` (path, size,
    mtime). Total size is bounded (default 500 MiB, LRU by access).
- `PosterQueue` (Core) does the work behind `wantImages(_:visible:width:)`:
  - It keeps only the latest request: a scroll replaces the queue, and visible cards go first.
  - Decodes run at `.utility` QoS. Parallelism is a share of the physical cores: start at `max(1, physical/2 - 1)`,
    capped at 4, as Loupe measured for images, then **measured for video** on the M4 Max and the Intel Mac before
    the constant is fixed (a bench in `docs/`, as `CLAUDE.md` asks).
  - Reads per volume: a network share gets 1 file in flight (`PathAvailability` / `NetworkPolicy` know which), a
    local disk the decode parallelism.
  - It pauses while the player plays or scrubs, and while Home is hidden (`pauseThumbs`). It resumes 300 ms after
    the foreground goes quiet.
- A file that cannot be decoded is cached as such, so it is not tried again until its mtime changes. Its card is
  dimmed through `setUnavailable`.
- The duration comes free with the poster (`KeyframeThumbnail` already returns it). It goes into `subtitle` with the
  resume progress from `ResumeStore`, so a folder's card shows "12:30 / 1:02:10" and a progress line, as Recent's do.

### Config and Settings

| Key | Default | Notes |
|---|---|---|
| `home-tab` | `recent` | replaces `start-tab` (`recent` / `folders` / `stash`), saved for the user's own moves only |
| `home-folder` | — | the last folder browsed (in UserDefaults, not the conf) |
| `home-sidebar` | `true` | |
| `home-card-size` | 220 | replaces `start-card-size` |
| `recent-count` | 50 | |
| `home-posters` | `true` | off: symbols only, no decoding (for a slow NAS) |

- `home-layout`, `start-tab` and `start-card-size` go, with no migration.
- Settings › General gets a Home group with these keys. The Home layout pop-up goes.

### Responsiveness budgets (CLAUDE.md)

| Action | Budget | How it is kept |
|---|---|---|
| First Home show at launch | ≤ 300 ms main thread | `HomeView` made once; Recent from memory, its pictures async |
| Video → Home, Home → video | ≤ 100 ms | parked view, toolbar swap only, no `reload()` if the folder did not change |
| Folder open | ≤ 100 ms on main | listing detached, names first |
| Scroll of a 10 000-video folder | no dropped frames | kit's virtualized grid, `PosterQueue` latest-only |

A bench (`scripts/bench-home.sh`, `CLOCK_THREAD_CPUTIME_ID` per action, first visit and return, 5 rounds) runs on
the M4 Max and the Intel Mac before the build is handed over.

## Plan

1. **Kit bump, no behaviour change.**
   - HomeScreenKit `from: "0.5.0"`, still on `HomeScreenView`; SettingsKit 0.5.0 too.
   - Add `scripts/kits-check.py` and `docs/kits.md` from Loupe (same order of closing a branch with its kits).
   - CI green.
2. **HomeView with Recent and Stash.** Parity with today's start screen: `FrameScrubHomeSource`, `RecentSource`, Stash
   as an app page, show and hide parked, keys and mouse. `HomeScreenView` is no longer used.
3. **Folders.**
   - `VideoListing`, Places with volumes, open with Home's sort into the playlist.
   - Returning to the video's folder with the video selected.
   - Rename and trash.
   - At this step cards show symbols and durations from the listing only.
4. **Posters.** `PosterStore` + `PosterQueue`, the bench, the constants measured, `home-posters`.
5. **Playlist source.** A page's `ListPlaylist` in the sidebar while it exists.

Each step is its own branch and PR. Kit changes go on a kit branch of the same name and are released as a tag before
FrameScrub takes them (`docs/kits.md`).

## Kit changes likely needed

- None for steps 1–3 as far as the 0.5.0 API shows.
  - `BrowserEntry` has `subtitle`, `progress`, `badge`, `isDimmed`.
  - `HomeSourceInfo` has `page` and `groupsByDate`.
  - `HomeClick` / `HomeResize` / `onOtherMouse` exist.
- Possibly for step 4: a card's picture aspect for video. `PhotoCard` fits the CGImage's own size, so 16:9 posters
  should just work; to be checked on the demo with `HOMESCREEN_STYLE`.
- Possibly: a card overlay for duration (bottom-right, like video apps) instead of `subtitle`. Decide after step 3
  is on screen.

## Open questions

1. Showing Home over an open video: pause and keep the file open (proposed), or close the file as ⌘W does?
2. Recent: a list with date groups (as Loupe) or keep today's large poster grid as Recent's card style?
3. Should Home replace the left slot's playlist panel when the playlist is a folder, since Home's folder view is the
   same list? Proposed: no, the slot stays the in-video playlist and Home is for choosing.
