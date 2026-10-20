<div align="center">

<img src="docs/images/icon.png" width="128" alt="FrameScrub icon">

# FrameScrub

**A frame-accurate video player for macOS. Scrub forward *and backward* through 4K without waiting — and keep the frames you love at full quality.**

For editors, reviewers, animators, photographers pulling stills from video — and anyone who has ever hit ← in a player and watched it freeze.

![macOS 26+](https://img.shields.io/badge/macOS-26%2B-black?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-VideoToolbox%20%2B%20Metal-blue)
![FFmpeg](https://img.shields.io/badge/FFmpeg-demux-green)
![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-green)
![Stash](https://img.shields.io/badge/works%20with-Stash-8a2be2)

<img src="docs/images/seek.webp" alt="FrameScrub playing CHARGE with the seek-bar preview and keyframe lens">

<sub><i>CHARGE</i> (Blender Studio, CC BY 4.0) in 4K AV1. Hover the seek bar: a preview of that exact frame and a lens of the keyframes around it.</sub>

</div>

---

## Why FrameScrub

- **Backward is as fast as forward.** A cache of decoded frames around the playhead fills in both directions in the background, so stepping back never waits for a keyframe — even in long-GOP 4K HEVC HDR.
- **Sound you can scrub, like tape.** Drag through a paused video and hear it the way a reel sounds under your hand: the pitch follows your speed, and scrubbing backward plays the sound in reverse. A single frame step plays a short blip of sound, so you can find a cue, a clap or the first word by ear. Prefer clean audio? `⇧⌥M` keeps the sound's own pitch.
- **Its own VideoToolbox pipeline.** Several frames in flight instead of one at a time: ~640 fps for 4K H.264 and ~730 fps for 4K HEVC at ~0.4 ms of CPU per frame.
- **Frames out at full quality.** Save the frame you're on as JPEG, 10-bit HEIC, 16-bit PNG or TIFF in the source colour space (BT.709, HLG, PQ), or export every frame of a range — optionally only the sharpest ones.
- **Cut without re-encoding.** Mark ins and outs, save them as clips — separately, joined, or everything *except* the marks — snapped to keyframes, losslessly.
- **NAS-friendly.** One shared read cache, MP4 indexes from the header, background index scans for MKV/WebM/TS: seeking over SMB stays quick on high-bitrate files.
- **Your library, your hands.** A start screen with Recent and your [Stash](https://github.com/stashapp/stash) library, mpv-style key bindings, MX Master 4 haptics, a TourBox Lite preset.

## Numbers

MacBook Pro, M4 Max, macOS 27. Reproduce with `scripts/measure-startup.sh` and `FRAMESCRUB_PERF=1 swift test --filter PerformanceTests`.

| | |
|---|---|
| **Launch → 4K H.264 frame on screen** | **~430 ms** (window at ~180 ms, first frame decoded at ~290 ms) |
| **4K H.264 decoding, own VideoToolbox session** | **~640 fps**, ~0.4 ms CPU per frame (FFmpeg's VideoToolbox hwaccel: ~150 fps) |
| **4K HEVC decoding** | **~730 fps** |
| **Backward scrubbing at 60 steps/s**, 1080p H.264 and 4K HEVC HLG | **0 misses**, p99 **0.02 ms** per step |
| **Scrubbing a 4K H.264 file with B-frames** | keeps up at **~240 fps** (frames nothing refers to are skipped) |
| **Auto colour + vibrance on a 4K frame** | **~1 ms** of GPU (analysis once per scene) |
| **Simulated NAS, 4K HEVC 30 Mbit/s** | single seeks in **70–160 ms**; holding a key, the picture follows within ~175 ms |

## Features

<table>
<tr>
<td width="50%"><img src="docs/images/stats.webp" alt="Stats panel"></td>
<td width="50%"><img src="docs/images/home.webp" alt="Start screen with Recent"></td>
</tr>
<tr>
<td><b>Stats panel</b> (<code>i</code>). Container, codec, profile, bit depth, the decoder in use (VideoToolbox, FFmpeg, software), exact frame index, sharpness, scene change, scaler, colour.</td>
<td><b>Start screen.</b> Recent videos with where you stopped and how far you got; resume positions are remembered per file.</td>
</tr>
<tr>
<td colspan="2"><img src="docs/images/cheatsheet.webp" alt="Keys cheat sheet"></td>
</tr>
<tr>
<td colspan="2"><b>Two keyboard layouts and every key in one sheet</b> (<code>?</code>). <i>Classic</i> is mpv-style; <i>left-hand</i> keeps everything under the left hand while the right one is on the mouse. <code>input.conf</code> applies on top of either.</td>
</tr>
</table>

**Playback and scrubbing**
- Frame stepping both ways, horizontal-scroll scrubbing, Precision Scroll on MX mice, shuttle at 1/2/4/8× forward and backward, scrub audio that plays backward like tape (`⌥M`).
- Scene detection: jump to the next scene or back to the start of this one.
- A-B loop, cut marks with drag-to-adjust edges, play only the marked parts.
- H.264, HEVC (incl. 10-bit HDR), AV1 on M3 and later, everything else through FFmpeg; MP4, MOV, MKV, WebM, TS and more.

**Picture**
- MetalFX upscaling and HDR tone mapping; Apple's neural super-resolution redraws a paused frame sharper.
- Per-scene auto colour and vibrance, remembered per file and per folder.
- Aspect overrides (16:9, 4:3, 2.35:1, square pixels, …).

**Saving**
- `s` saves the frame; `⇧S` exports an A-B range — every frame, every N-th, N per second, or only the sharpest of every N.
- `⇧⌘C` saves the marks as clips without re-encoding.

**Hardware**
- **Logitech MX Master 4** over HID++: haptic patterns you can feel for keyframes, marks, frame steps, the ends of the file, finished saves and errors; the thumb wheel, gesture and side buttons bound like keys.
- **TourBox Lite**: a ready-made preset in `extras/tourbox`.

The full list of keys, gestures and settings is in **[docs/reference.md](docs/reference.md)**.

## Stash

<img src="docs/images/stash.webp" alt="Stash library inside FrameScrub">

FrameScrub plays your **[Stash](https://github.com/stashapp/stash)** library natively. Set the address in Settings → Stash and the start screen gets a **Recent | Stash** switch with the Stash web UI in the window.

- ▶ on a scene opens the file in FrameScrub **straight from its share** — not a transcoded stream — mounting the share if needed (Windows drive letters and `\\server\share` paths are mapped for you).
- Previous/next and autoadvance follow the Stash list you came from: its filter, sort and pages.
- Watched time, resume point and play count go back to Stash exactly as Stash's own player reports them.
- The stats panel gets a Stash section with the scene's details; `⌘⌫` asks Stash to delete a scene and its files.

Stash support keeps growing in FrameScrub and in its sibling image viewer [Loupe](https://github.com/ampire5/Loupe).

## Under the hood

Native Swift and AppKit, with SwiftUI for settings and panels.

| | |
|---|---|
| **Demuxing** | FFmpeg's libavformat, with an index built from the MP4 header or scanned in the background for MKV, WebM and TS, so any frame can be found exactly. |
| **Decoding** | Its own VideoToolbox pipeline: `VTDecompressionSession` with several frames in flight for H.264, HEVC (8- and 10-bit) and AV1 on M3 and later; FFmpeg's libavcodec for every other codec. |
| **Frame cache** | Decoded frames live in IOSurface-backed pixel buffers in a cache around the playhead, which a forward and a backward worker keep filled, so stepping either way is a lookup, not a decode. |
| **Display** | A `CAMetalLayer` with EDR for HDR (HLG and PQ, tone-mapped where the screen can't show it), Core Image for colour, MetalFX upscaling, and VideoToolbox's frame processor for neural super-resolution of paused frames. |
| **Audio** | `AVAudioEngine` with a time-pitch unit for playback at any speed and for tape-style scrub audio (FFmpeg's libswresample converts the samples). |
| **I/O** | One shared read cache per file for every decoder (playback, backward, thumbnails, audio, export), which keeps seeks over SMB fast. |
| **Input** | mpv-style `input.conf`, trackpad and wheel gestures, the MX Master 4 over IOKit HID with [LogiHIDPP](https://github.com/ampire5/LogiHIDPP). |
| **Structure** | A SwiftPM package with no Xcode project: `FrameScrubCore` (demuxing, decoding, caches, playback, export, with no window code) and the app, on top of the shared packages HomeScreenKit, InfoPanelKit and StashKit. About 20 000 lines of Swift. |
| **Tests** | 1 095 tests in Swift Testing, run against generated fixture videos (exact frame numbers are drawn into every frame), including performance tests for decoding and simulated NAS seeks; CI on GitHub Actions. |

## Install

```sh
brew install --cask ampire5/tap/framescrub
```

Or download the zip from [Releases](https://github.com/ampire5/FrameScrub/releases) (it needs `brew install ffmpeg`). Builds are not signed with an Apple Developer ID yet; the cask clears the quarantine flag for you.

### Build from source

macOS 26 or later on Apple Silicon, the Command Line Tools (`xcode-select --install`), and FFmpeg:

```sh
brew install ffmpeg
scripts/make-app.sh --install      # → ~/Applications/FrameScrub.app
# or run it directly:
swift run -c release FrameScrub /path/to/video.mp4
```

## Configure

Settings (`⌘,`) has tabs for General, Scrolling, Saving, Display, Mouse & Trackpad and Stash. They edit two plain-text files, keeping your comments:

- `~/.config/framescrub/framescrub.conf` — mpv-style `key=value` settings;
- `~/.config/framescrub/input.conf` — bindings, `<input> <action> [args]`.

See **[docs/reference.md](docs/reference.md)** for every option.

## Tests

```sh
scripts/make-fixtures.sh                                 # generates Tests/Fixtures (once)
swift test
FRAMESCRUB_PERF=1 swift test --filter PerformanceTests   # also runs the simulated-NAS seeks (makes a 4K file once)
```

## Roadmap

Next up: subtitles and audio tracks, the shared Settings and Home from Loupe, a filmstrip in the seek bar — and a plugin architecture for media servers (Plex, Jellyfin, DLNA, HLS). See **[ROADMAP.md](ROADMAP.md)**.

## Credits

Screenshots show *CHARGE* and *Spring* by Blender Studio (CC BY 4.0) and launch footage by NASA (public domain).

## License

GPL-3.0-or-later (see [LICENSE](LICENSE)). FrameScrub uses [FFmpeg](https://ffmpeg.org) (LGPL/GPL), the MIT-licensed packages [HomeScreenKit](https://github.com/ampire5/HomeScreenKit), [InfoPanelKit](https://github.com/ampire5/InfoPanelKit) and [StashKit](https://github.com/ampire5/StashKit), and [LogiHIDPP](https://github.com/ampire5/LogiHIDPP) (GPL-3.0).
