# Grain Candidate Integration Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans inline in this existing isolated worktree.

**Goal:** Make the tested AV1-style and particle grain available in the experimental player.
**Architecture:** Package the exact neutral FP16 banks from the approved external experiment as Core resources, load once during off-main pipeline preparation, and use the existing fused/general compositors. Preserve old banks and their sampling, ordering, frame seeds and HDR bypass.
**Tech Stack:** Swift, Metal, SwiftPM resources, Swift Testing, native AppKit settings.
**Spec:** User approved the preceding concrete proposal with “Делай”: two new grain choices, larger strength range, experimental build, pause/playback/scrub checks.

## Global Constraints

- Keep source cleanup before MetalFX and grain after cleanup/sharpening; no new frame queue or history.
- Preserve Off/White/Fine/Soft and all current defaults; H.274 is excluded from this integration.
- New modes `av1` and `particles`; amount range0…12, existing size.5…4, adaptation0…1.
- Working presets use amount6, size2, base.8, adaptation1 with strong Window cleanup; do not set global defaults.
- Exact candidate banks have16 layers64×64 R16F,131072bytes each. Preserve source/license/provenance, no private media/config paths in repository assets.
- No commit, merge or push. Preserve other uncommitted work. Package a separate lab app/config.

## Review Focus

- New resource-backed modes use correct layer/dimension sampling without changing old styles.
- Missing/malformed resource fails safely during preparation; no frame-time I/O or CPU synthesis.
- Strong grain still protects texture, is deterministic paused/reverse, and is not sharpened.
- Actual packaged app resolves resources without relying on the build directory.
- Menu and Settings choices persist; full-grain demo does not accidentally disable protection in working presets.

### Task 1: Modes, resources and rendering

- [x] Add failing config tests for `av1`/`particles`, amount6/12 and invalid12.1.
- [x] Add GPU tests for both modes: visible amplitude on a flat field, deterministic seeds, distinct outputs, protection of luma/chroma texture. Parameterize fused-vs-separate test for both modes.
- [x] Run focused tests and observe expected failure before implementation.
- [x] Package exact two banks and attribution, add a validating resource loader and correct texture selection/sampling for64px×16-layer banks. Keep128px×4-layer old sampling unchanged.
- [x] Add enum values, config range, Settings choices/help, explicit working presets to existing menu.
- [x] Run focused then full tests, release build. Fresh read-only review of this change; fix actionable findings.

### Task 2: Deliverable and verification

- [x] Update architecture/resource packaging and bench notes. Ensure normal make-app and separate lab copy the Core resource bundle.
- [x] Measure current DisplayScaler changing4K→6K frames and off-main preparation cost; verify output against external bank samples within rounding tolerance.
- [x] Sign/verify a separate experimental lab with AV1 working preset and an isolated config; retain old apps/configs.
- [x] Launch and check resource-backed modes on pause, A/B, playback and source-frame seeking. Record exactly what was observed and any remaining native-automation limitation.
- [x] Show a sample and report app path, controls, tests and material limits.

## Execution ledger

Ruling: use immutable packaged banks instead of reproducing CPU synthesis in the app — preserves the exact evaluated appearance and avoids startup simulation; costs256KiB of resources.
Ruling: retain size/seed/block behavior by querying texture dimensions/layers in the shared shader — new banks and old banks share one pipeline without changing old numeric constants.

Final verification: 1854 Core +35 Settings tests pass; release42.87s; fresh read-only review no actionable findings. Exact bank regeneration and six6K PNG comparisons pass (zero RGB8 difference). Native6K pause/menu/A-B/playback/seek checks and bounded actual-presentation/scrub diagnostics pass after leaving the older fullscreen Space. Initial occluded runs retained and excluded. Settings edits18–20ms. No power/thermal claim; no commits.
