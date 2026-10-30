# Posters from a share (2026-10-27)

The owner's report: a folder of many videos on the NAS makes FrameScrub generate posters "with wild multithreading"
and the system gets sluggish. Reproduced before anything is changed (CLAUDE.md).

**Machine.** Apple M4 Max, 14 physical cores; a NAS over SMB,
a folder of 101 1080p H.264 files.

**How.** `FRAMESCRUB_POSTER_DIR=<folder> [FRAMESCRUB_POSTER_WORKERS=n] [FRAMESCRUB_POSTER_SKIP=k] swift test --filter
SharePosterBench`: 12 posters (`KeyframeThumbnail.make`, the poster queue's own call), wall time, the process's CPU
time, the most threads seen (sampled every 20 ms).

| Workers | Posters | Wall | Each | CPU | Peak threads |
|---|---|---|---|---|---|
| 1 (the app's on a share) | 12, cold | 2.9 s | 0.24 s | 0.3 s (9 % of a core) | 13 |
| 3 (the app's on a local disk) | 12, cold | 1.7 s | 0.14 s | 0.2 s (9 % of a core) | 17 |

`URLResourceValues.volumeIsLocal` is false for these shares, so the app makes one at a time there.

**Reading.** The poster itself is cheap on this machine (hardware H.264, a 2 MB read or so): it does not explain the
load. What else runs while a NAS folder is open is the next thing to measure, in the app (`sample` of FrameScrub with
the folder on screen): the folder cards' summaries and covers (a listing and four posters per subfolder), the posters
ahead for the rest of the folder, Recent's queue, the facts probes.

**In the app (2026-10-27, 04:00–04:10).** FrameScrub watched every 2 s with folders open on the NAS: at most 97 % of
one core for a moment, 25–40 threads, otherwise under 10 %; never more than a core. The owner withdrew the report
("показалось"). Nothing changed in the queue.
