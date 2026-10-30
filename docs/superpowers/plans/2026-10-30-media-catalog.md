# Media catalog implementation plan

Goal: replace disposable facts JSON and loose thumbnail storage with an indexed SQLite cache. Existing positions and colour settings remain user data; no JSON import or deletion.

Architecture: lazy SQLite WAL connection, serialized access on background callers. File identities contain normalized path, device, inode, size and nanosecond mtime. A complete versioned metadata result records checked-but-absent values. SQL indexes support addressed reads and transaction batches; namespaces distinguish last-frame images from posters. Image payloads and metadata have explicit budgets and oldest-used eviction. Corrupt disposable catalog is quarantined and recreated, never positions.json.

- [x] Add catalog tests: persistence, same-size replacement, mtime, versions/absence, bounded payloads, corruption, batch lookup.
- [x] Implement SQLite catalog and bounded JPEG payloads; benchmark blobs vs separate files before selecting final storage.
- [x] Extract bounded container/stream metadata at existing source opens; reject writes if source identity changes during probing.
- [x] Replace FileFactsStore and ThumbnailStore internals; request only displayed/listed identities, no startup catalog load. Deliver cached facts through item updates.
- [x] Separate viewing time from colour/state updates without rewriting old user records.
- [x] Run targeted tests and real first/repeated lookup bench; inspect diff for private data; retain local changes on polish-3.

Review focus: same-size overwrite, file replaced while decoding, reader upgrade with absent fields, concurrent readers/writers, corrupt/read-only cache. No kit changes or dependency pin edits.

Independent review found and prompted fixes for playback frame identity, inspector cancellation/concurrency, and retention scans at capacity. Final re-review and full-suite verification recorded in the completion report.
