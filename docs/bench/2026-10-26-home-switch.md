# Home ↔ video: main-thread cost

Date: 2026-10-26.

**Machine.** Apple M4 Max, macOS 27.0. HomeScreenKit `home` on top of `polish`.

**Not measured yet: the Intel Mac.** It is the slowest supported machine, so it is the one the budget is checked on (CLAUDE.md).

**How.**
- Built with `FRAMESCRUB_STARTUP_TRACE=1`.
- `showHome` and `hideHome` read `CLOCK_THREAD_CPUTIME_ID` before and after. In bench mode they also force the window's layout and drawing, so the cost the run loop would pay afterwards is counted too.
- Four recent videos.
- The first show happens at launch (Recent empty), then six rounds: ⇧⌘H over a paused video, then Esc.

| Action | Budget | Main-thread CPU | Wall |
|---|---|---|---|
| Home, first show (made, attached, listed) | 300 ms | 107 ms | 115 ms |
| Video → Home (rounds 1–6) | 100 ms | 34, 29, 26, 26, 27 ms | 30–39 ms |
| Home → video (rounds 1–6) | 100 ms | 18, 16, 16, 15, 15, 20 ms | 15–48 ms |

**Reading.**
- No round gets slower than the one before, so nothing accumulates.
- Video → Home costs more than the reverse. It saves the position (JSON) and the frame (handed to a queue), swaps the toolbar, and re-lists Recent from the stores.
