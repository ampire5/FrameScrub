# Cache controls and view history

Goal: expose thumbnail encoding policy in both apps, manage FrameScrub's SQL cache, persist actual last view independently of resume settings and disposable caches.

Architecture: existing settings stores bridge UserDefaults encoding policy; lazy cache statistics/commands run on utility workers. View history remains user state. Loupe and shared HomeScreenKit are owned by the existing Loupe chat; FrameScrub changes stay here.

- [x] FrameScrub format/quality, poster/last-frame sizes and storage limit, validated and resettable; restart wording.
- [x] Lazy statistics, explicit image/full disposable-cache clear, local-only stale cleanup in bounded batches; menus and settings share actions.
- [x] Actual-view timestamps independent of resume; worker snapshots and field-wise disk transactions preserve colour/marks and other running copies' changes.
- [x] Visibility includes paused Home return; hidden/occluded frames and unshown preparation do not create visits.
- [x] Async termination barrier captures session state before closing and flushes user state before exit.
- [x] Full 1784 core + 35 settings tests passed; final compatibility tests 15 passed. Independent review has no outstanding findings.
- [x] Real settings-window benchmark and screenshot inspection; release app rebuilt after final changes.
- [x] Loupe owner final verification and build handoff: installed ~/Applications/Loupe.app; release build in Loupe/build/Loupe.app.

Constraints: no startup library scan; no disk I/O on main; user history survives cache clear; no external runtime codec dependencies; no push/merge.

Measured limitations: cold Performance totals 122 ms CPU (longest turn 41 ms), return 11–13 ms; existing settings-window opening 433 ms exceeds the ~300 ms goal. Intel and SMB remain unmeasured. Results are in docs/bench/2026-10-30-media-catalog.md.

Loupe owner handoff: kit 684 tests passed. Loupe standard run 2252 tests / 7 skipped; two existing strict-timeout tests failed under parallel load and passed separately (.105/.118 s), so the full run is not labelled all-green. Native presentation/history bench passed; independent review findings resolved; build and installed bundle signatures verified by owner. Settings Strip first CPU total 157 ms, max uninterrupted turn 24 ms, returns 10 ms; Intel unmeasured.
