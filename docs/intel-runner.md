# The Intel Mac runner

CI's x86_64 job cross-builds `main` for Intel Macs (macOS 26, Xcode 26) on an Apple Silicon image and tests it under
Rosetta: the CPU code is covered, but the GPU, VideoToolbox and the memory model are Apple Silicon's. The **Intel Mac
(self-hosted)** workflow of FrameScrub and of Loupe runs the same build on a real Intel Mac with macOS 26:

| | FrameScrub | Loupe |
|---|---|---|
| Tests | all, native x86_64 | the core suite and the Metal render tests (`scripts/test.sh render`) on the Mac's own GPU |
| App | `scripts/make-app.sh` | `scripts/make-app.sh` |
| Dependencies | prebuilt FFmpeg (`scripts/deps.sh`) | prebuilt decoders (`scripts/deps.sh`) |
| Test videos | taken from the latest successful cloud CI run (artifact `fixtures`) | — |

It runs by hand only for now (Actions → *Intel Mac (self-hosted)* → Run workflow): with no runner registered, runs on
every push waited a day and failed. When the runner is registered, put back its push trigger (`push: branches: [main]`,
ignoring `**.md` and `docs/**`).
**Never on pull requests**: the runner is a personal computer.

## The Mac

- macOS 26 on an Intel Mac, logged in (the runner runs in the user session: Metal needs it), not sleeping while it
  should take jobs.
- Xcode 26 (or the Command Line Tools for Swift 6.2), selected with `xcode-select`. Xcode also gives `actool` for the
  app icon.
- Nothing from Homebrew while the prebuilt dependencies are published (the *Prebuilt dependencies* workflow).
  Without them `scripts/deps.sh` builds from source and needs `brew install nasm meson ninja pkgconf` (FrameScrub) or
  `brew install cmake ninja nasm pkgconf` (Loupe); Homebrew builds those from source on Intel now, which takes a while
  once.

## Registering the runners

One runner per repository (personal accounts have no runner groups), both on the same Mac in their own folders.
For each of FrameScrub and Loupe:

1. GitHub → the repository → **Settings → Actions → Runners → New self-hosted runner**, macOS, x64.
2. On the Mac, in a new folder (`~/actions-runner/framescrub`, `~/actions-runner/loupe`), run the download commands
   GitHub shows, then configure with the label the workflow asks for:

   ```sh
   ./config.sh --url https://github.com/ampire5/FrameScrub --token <token from that page> \
       --name intel-mac --labels intel-macos26 --unattended
   ```

3. Run it as a launch agent, so it starts with the login session:

   ```sh
   ./svc.sh install
   ./svc.sh start
   ```

`./svc.sh stop` / `./svc.sh uninstall` and `./config.sh remove --token <token>` take it back off.

## Security

The repositories are public. A self-hosted runner runs whatever a workflow tells it to, so:

- **Settings → Actions → General → Fork pull request workflows from outside collaborators: Require approval for all
  outside collaborators.** A pull request from a fork that adds a job for this runner then waits for your approval;
  read its workflow changes before approving.
- The workflow itself only runs on pushes to `main` and by hand.
- The runner works as your user: keep it on a Mac (or a separate macOS user account) without secrets you would not
  hand to a build script.
