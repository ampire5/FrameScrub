# LTS policy: `lts/macos26`

macOS 26 Tahoe is the last macOS for Intel Macs. `main` moves on with Apple Silicon and newer macOS; the
`lts/macos26` branches keep FrameScrub and Loupe working on **Intel Macs (x86_64) with macOS 26**.

## Scope

| | |
|---|---|
| Repositories | FrameScrub, Loupe, and the packages they use: LogiHIDPP, InfoPanelKit, StashKit, HomeScreenKit, SettingsKit — each has a `lts/macos26` branch |
| Platform | macOS 26, x86_64 only. Apple Silicon users stay on `main` |
| Toolchain | Xcode 26 (Swift 6.2), the newest 26.x on GitHub's runner |
| Supported until | Apple's last macOS 26 security update (expected autumn 2028); the date is fixed in this file once Apple stops |

## What comes over from `main`

Changes flow one way, `main` → `lts/macos26`, as cherry-picks. Nothing is merged back.

1. **Always:** security fixes, crashes, data loss, and breakage from macOS 26.x updates.
2. **Usually:** other bug fixes, when they apply cleanly or nearly.
3. **Selectively:** features. A feature comes over when it needs nothing newer than the macOS 26 SDK and Swift 6.2, and
   its cost on the branch is reasonable. Features that depend on macOS 27+ APIs, Apple Silicon-only hardware, or
   Xcode 27 stay on `main`.

Fixes that only matter on Intel (discrete GPUs, older VideoToolbox) are made directly on `lts/macos26`.

## How a backport works

- Label the pull request on `main`: **`backport:lts`** (fix) or **`backport:lts-feature`** (feature).
- When it merges, the *Backport to LTS* workflow cherry-picks it onto `lts/macos26` and opens a pull request there;
  on a conflict it opens one with the conflict to resolve by hand.
- A change spanning a package and an app is backported in both repositories; the package first.
- The LTS pull request must pass the LTS CI (x86_64 under Rosetta) before it merges.

## Builds and releases

- The apps on this branch link their native libraries in statically (FrameScrub: FFmpeg and dav1d; Loupe:
  libjpeg-turbo, libjxl with its brotli and highway, libheif for the bench), built from source by
  `scripts/build-deps.sh` at pinned versions. Homebrew no longer builds Intel bottles, so the Intel apps need no
  Homebrew at run time.
- **Prebuilt dependencies.** `scripts/deps.sh` (called by the build scripts) downloads the build of the current recipe
  from the repository's pre-release `deps-x86_64-<hash of build-deps.sh>` (SHA-256 checked) into `.deps/x86_64`, and
  builds from source only when there is none. CI, releases and local builds therefore link the same binaries. After
  changing `build-deps.sh` (a version bump, a security fix), the **Prebuilt dependencies (x86_64)** workflow builds and
  publishes the new recipe on its own once the change is on `lts/macos26`; until then builds compile it themselves
  (CI also keeps it in its cache).
- The apps depend on the packages' `lts/macos26` branches, not on version tags.
- Releases are tagged **`vX.Y.Z-lts`** on `lts/macos26` and ship `…-macOS-x86_64.zip`. They are not marked
  latest on GitHub. The release workflow updates the `on_intel` block of the Homebrew cask; `main`'s releases update
  `on_arm`, so `brew install --cask ampire5/tap/framescrub` picks the right build on either Mac.
- Version numbers follow the `main` release a backport set comes from, with the `-lts` suffix (`v0.2.0-lts`); a
  fix-only LTS release bumps the patch number.

## Testing

GitHub has no Intel runner with macOS 26, so CI builds and tests x86_64 on the Apple Silicon `macos-26` image under
Rosetta. The CPU code paths are covered; the GPU and the hardware decoders are the Apple Silicon ones there. The
**Intel Mac (self-hosted)** workflow runs the tests (Loupe's Metal render tests included) and the app build on a real
Intel Mac when one is registered as a runner ([docs/intel-runner.md](docs/intel-runner.md)). Before an LTS release,
also check by hand on that Mac: playback of H.264, HEVC 8- and 10-bit and AV1 (software on Intel),
scrubbing, Metal rendering on the Mac's own GPU (integrated Intel or AMD), and the Logitech mouse features.
