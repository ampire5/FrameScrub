# Roadmap

FrameScrub is made by one person in their spare time, so there are no dates here — just the order things are likely to happen in. Bugs are always fixed first. Ideas and votes are welcome in [Issues](https://github.com/ampire5/FrameScrub/issues).

## Next

- **Subtitles and audio tracks.** Embedded and external subtitles, switching between audio and subtitle tracks, remembered per file.
- **The shared Settings window and Home** from [Loupe](https://github.com/ampire5/Loupe): the same Settings layout, and a Photos-style start screen with a sidebar, Recent and Stash.
- **A filmstrip in the seek bar.** A continuous strip of keyframes along the timeline, as in QuickTime's trim view, alongside the existing hover preview.
- **Small conveniences:** jump back to where you were before a seek, previous/next keyframe, go to a time or frame number (`⌘G`), hold a key for 2× speed, the frame type (I/P/B) in the OSD, always on top.
- **The window** opens at 1:1 when the video fits and remembers where you put it.

## Planned

- **A contributing guide**: how to build, test and send a pull request, plus the code layout and conventions.
- **FFmpeg inside the app**, so the Releases zip works without `brew install ffmpeg`.
- **Stash streaming** for scenes whose files aren't reachable over a share: playback straight from Stash over HTTP, with the same read cache.

## Exploring

- **Media-server plugins.** A documented plugin architecture shared with Loupe: a *source* (library, metadata, watched state, resume points, history) and a *transport* (local path, share, HTTP range requests, HLS). The existing Stash integration becomes the first plugin; others — Plex, Jellyfin, Emby, DLNA, plain HLS streams — are open to the community.
- **Real-time neural upscaling** during playback (`VTLowLatencySuperResolutionScaler`), and integer scaling for pixel checks.

## Not planned

- **Developer ID signing and notarization** — not for now. Install with Homebrew (it clears the quarantine flag) or allow the app once in System Settings.
- **Intel Macs and macOS before 26.** FrameScrub's pipeline is built on VideoToolbox and Metal on Apple Silicon.
- **Zoom and pan inside the video, bookmarks, chapters.** FrameScrub stays a keyboard-first scrubber.
