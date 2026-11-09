# Virtual cuts

A saved cut plays selected ranges from one or more source videos on a single
timeline without creating a media file. The first release includes analysis
and review of one open Stash scene at a time, a shared cut editor and
catalog on the provider machine, and native playback in FrameScrub.

The panel shows matching cached analysis when a scene opens. New analysis
starts explicitly, has a durable job ID, is cancellable, and continues
when the window or scene closes. The panel shows stage and measured counts
when available, then publishes one stable list of results without seeking
the player. Scene drafts preserve model boundaries, edits, selection, and
order. Only selected ranges are copied into a named cut. Later changes to
the scene draft leave those copies independent. Editing a saved cut opens
the original timeline, allowing either boundary to move beyond the old
range. Shared writes use revisions. Conflicts offer reload or save a copy.

Each range carries its own stable ID, source identity and version, and start
and end. The playable timeline unions overlapping selected ranges of the
same source version and places the union at the earliest original position.
The editor keeps the original ranges. The timeline uses an exclusive end
so touching ranges do not overlap. During playback, the host maps virtual
position to source position. It preserves speed, volume, and play state
across sources, prepares one upcoming source if foreground work allows,
and shows waiting when a new source needs time. Unavailable or changed
sources offer retry or skip. The cut stops at the last frame by default.
An explicit loop wraps the cut. Opening the original at the current frame
offers return to the cut at the previous position. Resume is separate from
source history and follows the original range ID through edits when possible.

The provider registers a source in the native File View sidebar. Cards show
up immediately and fill their mosaics lazily from up to four frames, using
different sources when available. The browser retains selection on return.
Open or Enter plays the cut. Edit is a separate action. The public provider
contract uses neutral media types; a private adapter translates Stash and
the installed analysis tools. The provider owns persistence and jobs; the
host owns source validation, playback, seeking and presentation.

## Approaches

- Render a file first. Simple playback, but iterating on edits requires
  re-rendering. The agreed first release is virtual playback.
- Have the plugin send a chain of seek/open commands. Reuses today's
  bridge but cannot implement reliable seeking on a single native timeline
  or provide a stable playback clock across a source change.
- Use a host-owned virtual timeline and one real playback session at a
  time. Reuses decoding, indexing and display behavior and gives the host
  a consistent position for scrubbing, switching and resume. Selected.

The following release can submit an immutable cut revision to the provider
for frame-accurate file export, with progress. It uses the same resolved
range order as virtual playback. Do not ship the private provider, source
paths, model names, or class taxonomy in the public repository.
