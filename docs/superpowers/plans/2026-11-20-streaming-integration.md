# Streaming Integration Implementation Plan

> Use Superpowers implementation and verification skills. Verify each entry point and failure path before handing over the build.

**Goal:** Integrate public video pages and direct streams with the FrameScrub window, Recent, Info, and external callers.

**Architecture:** The window owns one cancellable open request and prepares the next stream before replacing playback. Core owns the selected format, decoded playback and local resume, keyed by the stable page item. External and plugin requests preserve their existing link and bridge semantics.

**Tech Stack:** Swift, AppKit, WebKit, FFmpeg, yt-dlp, gallery-dl, Swift Testing.

**Spec:** The decisions approved in the streaming integration interview.

- [x] Parse external web links and plugin page opens while retaining existing file, scene and direct stream opens. Verify malformed URLs, percent encoding and optional landing.
- [x] Retain stable source item identities and selected-format metadata from the extractors. Verify that retries can resolve another signed URL for the same item and that site login errors produce actionable copy.
- [x] Prepare network requests on the existing worker and enforce one current request, with status, cancellation and retry. Preserve the active video through extraction, selection and preparation.
- [x] Restore position and marks, reopen an exact gallery item from Recent, and reconnect at the last displayed frame. Confirm that cancellation and another open invalidate reconnect work.
- [x] Document supported calls with neutral examples. Run targeted tests and package a signed preview.

Verification covered 302 targeted tests, the actual window opening through both entry points, cancellation and failure with the previous video retained, Recent with reordered results and fresh media URLs, reconnect at a paused frame, a macOS URL open event, and the Page Preview signature.
