# Filter controls and independent filmstrip

User direction: simplify filter controls, offer them in a player slot, use an easy shortcut,
explain debanding choices, fix empty filmstrip. Auto activation is deferred.

- [x] Reproduce: preview=no returns before creating the filmstrip loader; preview=yes restores the ribbon.
- [x] Keep the hover provider conditional; configure the bounded utility filmstrip loader independently.
- [x] Add remappable N / Option-N commands without disturbing B (save clips in left-hand layout).
- [x] Add a lazy native Filters tab to the shared slot host, preserving shared settings/presentation.
- [x] Explain algorithm tradeoffs and offer explicit starting settings without resetting unrelated filters.
- [x] Verify tests, release build, real-window control latency and ribbon with preview=no; package a reviewable build.

No filter kernel changes or new temporal/GPU passes. Existing player settings are retained.
