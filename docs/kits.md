# Kits and branches

FrameScrub builds on its kits (HomeScreenKit, SettingsKit, StashKit, InfoPanelKit, LogiHIDPP), each its own repository
beside FrameScrub (`../<Kit>`). Package.swift takes each from a released tag (`from:`), Package.resolved pins the tag's
commit, and CI builds exactly those pins. Locally a kit can be in `swift package edit` mode (`Packages/<Kit>` → the
clone), so FrameScrub builds against the kit's working copy; SwiftPM then writes Package.resolved without that kit's pin.

A local `.swiftpm/configuration/mirrors.json` (not in git) may point the kits' URLs at the clones beside
FrameScrub: SwiftPM then resolves the same tags from the clones, so a tag must exist there (fetch the kit) before
`swift package update` finds it; Package.resolved still records the GitHub URLs.

`scripts/kits-check.py` checks all of it: run it before a branch is merged and before a build is handed over.

## While a branch is open

- Kit work for FrameScrub's branch `X` goes on a branch `X` in the kit's repository, not on the kit's `main`.
- FrameScrub builds against it in edit mode; Package.resolved is not committed from edit mode (`git checkout
  Package.resolved` after a build that rewrote it).

## Closing a branch, in this order

1. **Kits first.** In each kit with a branch `X`: tests green, `X` merged into the kit's `main` (PR), pushed.
2. **Release the kits.** A new tag on the kit's `main`: a patch version for a fix, a minor one for new API (0.x).
   Push the tag.
3. **FrameScrub takes the release** on its branch `X`: `from:` in Package.swift raised when FrameScrub needs the new API (a
   fix alone needs only the pin), `swift package update <Kit>` outside edit mode, so Package.resolved pins the new tag.
   `scripts/kits-check.py` must say `kits: ok`. Commit as `Package: <Kit> <version>` with Package.resolved.
4. **FrameScrub's CI green** on `X`, then `X` is merged into FrameScrub's `main`.
5. **Clean up.** The kits' and FrameScrub's branch `X` deleted (local and origin), each kit's clone back on `main` and
   pulled; edit mode left on only if more kit work follows.

A kit is never released from a branch, and FrameScrub never pins a kit's branch or an untagged revision: `main` of FrameScrub
must build from the tags alone.
