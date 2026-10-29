# Viewing timeline and floating transport

Date: 2026-10-29. Selected in chat: automatic floating controls ("1"); implementation authorized by "Да, давай".
Reference: `framescrub-floating-controls.html` in this chat's visualizations; source ideas in the user's
`Downloads/Лента во FrameScrub.html` and the F2–F4 filmstrip designs.

## Intent and scope

Viewing comes first. Show a full-width film under a stationary centre, with a nonlinear lens: seconds near the
current frame, increasingly large intervals towards the ends. Keep a separate linear overview for direct seeking.
Transport must not consume the film's width or add a permanent row. Editing features remain separate: existing
marks, A–B and export commands keep working, but do not add editing buttons to the viewing transport.

## Approaches

The initial centred permanent transport took too much height. Moving controls beside the film reduced height but
took width and over-emphasized Play. The user selected dark translucent floating capsules, automatically revealed
over the film's upper corners, with the film occupying the full width. A permanently visible option remains useful.

## Behaviour

- Left capsule: Play/Pause, −10 s, +10 s. Small round Play, light symbol on dark glass, no white disc.
- Right capsule: mute/volume, speed, full screen. Subtitles appear only when the app actually supports them; it
  currently does not. No inert subtitle control. Volume may expand to a slider; speed offers explicit rates.
- Entering the bar reveals controls; leaving hides after 0.6 s. Menus, drag and keyboard access keep them visible.
  The fade is 0.15 s, with no endless activity. Controls have tooltips and accessibility labels. Keyboard commands
  continue to belong to the video; controls do not steal the player's shortcuts.
- Film height starts at 48 pt, can be increased or hidden in its context menu. The actual strip, its time labels,
  and the overview fit below the capsules. Only capsules overlap the image. In narrow windows fewer cells are drawn,
  never smaller hit targets or squeezed timestamps. First/last file regions remain reachable.
- The lens uses seconds, not frame fractions (variable-frame-rate files included). It freezes on press; dragging
  moves that frozen scale under the centre. Release recentres the scale without changing the selected frame.
  No snapping to thumbnail times and no inertial seek after release. A cancelled gesture retains the latest position.
- Direct overview seeking uses time, preserves pause/play, and follows the existing configured seek precision.
  Hover preview remains available on the overview. Film clicks go to the requested position, independently of a
  previously pinned hover preview. The overview retains cache, marks and A–B indicators.
- At either file boundary empty space is allowed on the exhausted side; do not duplicate beginning/end frames to
  pretend there are more moments. Zero-length and unknown duration show a disabled, finite timeline.
- Keep the current player's panel reveal/hide behaviour; no polling or decoding when hidden or the window is not
  visible. Existing mouse viewing/editing profiles are not redefined by this UI change.

## Loading and performance

Reuse PreviewProvider's keyframe decoder and shared ReadCache, with a single utility worker for the film. Requests
are bounded by visible cells, coalesced after dwell; user hover preview stays userInitiated. No film reads during
playback or an active seek gesture. Existing thumbnails remain visible. Stop and invalidate requests on file change.
Cache a bounded number of small images. Never create a worker per cell, decode on the main thread, or scan the file.

Measure the real view in a window with CLOCK_THREAD_CPUTIME_ID: first layout, returns, position updates, narrow
layout and control reveal, several rounds. Record the machine and limitations in `docs/bench`. Intel verification
is required before declaring its responsiveness verified there.

## Validation

Pure tests: monotonic lens mapping, seconds near centre, exact endpoints when both sides fit, inverse round trip,
frozen drag, short/empty/non-finite input, and linear overview independence. Integration: build with the existing
dependencies, run the full test suite, exercise first/last frames and narrow windows, review worker cancellation.
# Visibility and input follow-up

User clarification: mouse motion reveals progress and side playback controls; an enabled film reveals only when
the cursor enters its lower zone. Fold after 500 ms outside, except pinning or active input/menu. Cmd-L folds or
reveals; Option-Cmd-L persists pinning. Disabled/folded films start no thumbnail reads; existing hover-preview
images may be reused. Indexing itself must remain free of image decoding. Playback chrome may hide independently
of a pinned film. Horizontal scroll seeks continuously; vertical scroll steps keyframes; Option-scroll adjusts
local lens scale. Clicking a cell selects its sample time precisely, while overview retains configured precision.
Per-image display must not wait for a later input event. Toasts clear both windowed and fullscreen titlebars.

## Adaptive lens parameters

Expose seconds per full central thumbnail, precise-area fraction and adaptive horizontal crop strength. Keep
the central picture full, crop denser cells around their image centre and pack additional independent samples
into the freed space. Hover reveals the full image. One shared, bounded layout defines sampling, painting and
input; capture it for drag so changing the playback position does not change geometry under the pointer.
Use a native context popover with three live sliders, numerical values and reset; persist changes. Scale remains
available via Option-scroll. These are viewer controls and do not change selection or expose editing tools.

## Stable film and view selector

Confirmed metaphor: Whole File Lens moves a local magnifier over a stationary full-file film; Segment passes
absolute-grid pictures through a stationary central lens. Whole File shows the same complete film without a lens.
Expose all three in the sketch's on-film capsule, with context-menu equivalents and persisted choice. A view change
does not move the playhead or pause playback. Samples keep absolute identities/times during playback; only their
projection, size and centre crop change. Whole-file remote geometry is untouched outside the magnifier. New
Segment samples enter only at the viewport edges. The previous centre-relative resampling/rigid drag picture
model is replaced: capture the projection for input, continue projecting the actual film while dragging.

## Direct, independent lens controls

The on-film capsule includes a sliders button opening a compact live dropdown. Magnification, lens footprint and
outside density are independent controls; keep crop and Segment time step as additional controls. Magnification,
area and crop do not resample or decode pictures. Density/step may require new sample times, served by the bounded
caches/serial loader. Retain the content across opens, persist values, and allow previews to fill while editing.
Prevent enlarged edge pictures obstructing controls: reserve their rectangles in hover placement, keep controls
above the image and prioritize their hit targets. Crossing directly into a capsule dismisses the hover.
