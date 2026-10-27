# Roadmap

FrameScrub is made by one person in their spare time, so there are no dates here — just the order things are likely to happen in. Bugs are always fixed first. **What would make FrameScrub work better for you?** Tell me in a [feature request](https://github.com/ampire5/FrameScrub/issues/new?template=feature_request.yml): what you want to do, how you do it today, and what your collection looks like. Requests and 👍 on existing issues decide what comes next.

## Next

- **Light, dark or system theme everywhere.** The start screen, the playlist panel and the other dark-only windows follow the choice in Settings.
- **Subtitles and audio tracks.** Embedded and external subtitles, switching between audio and subtitle tracks, remembered per file.
- **A filmstrip in the seek bar.** A continuous strip of keyframes along the timeline, as in QuickTime's trim view, alongside the existing hover preview.

## Recently shipped

- The shared Settings window from [Loupe](https://github.com/ampire5/Loupe) (SettingsKit): search, every setting with its default, Key Bindings, the colour a video or folder sets; and Home, a Photos-style start screen with a sidebar, Recent, folders and Stash.
- Go to a time or frame number (`⌘G`), and back to where you were before a seek (`Shift+Backspace`).
- Previous / next keyframe, and the keyframe lens on the seek bar.
- Hold a key for 2× speed; the frame type (`K`, `I`, `P`, `B`) on every frame step; float on top (`T`).
- The window opens at 1:1 when the video fits and remembers its size and place.

## Planned

- **Logitech, deeper.** More of the mouse's own features and more events worth feeling, mice connected over Bluetooth without a receiver, and more HID++ devices as people test them.
- **A contributing guide**: how to build, test and send a pull request, plus the code layout and conventions.
- **FFmpeg inside the app**, so the Releases zip works without `brew install ffmpeg`.
- **Stash streaming** for scenes whose files aren't reachable over a share: playback straight from Stash over HTTP, with the same read cache.

## Exploring

- **Media-server plugins.** A documented plugin architecture shared with Loupe: a *source* (library, metadata, watched state, resume points, history) and a *transport* (local path, share, HTTP range requests, HLS). The existing Stash integration becomes the first plugin; others — Plex, Jellyfin, Emby, DLNA, plain HLS streams — are open to the community.
- **Real-time neural upscaling** during playback (`VTLowLatencySuperResolutionScaler`), and integer scaling for pixel checks.

## Not planned

- **Developer ID signing and notarization** — not for now. Install with Homebrew (it clears the quarantine flag) or allow the app once in System Settings.
- **macOS before 26.** Intel Macs are built for as long as they get macOS 26; nothing newer runs on them.
- **Bookmarks, chapters.** FrameScrub stays a keyboard-first scrubber.
