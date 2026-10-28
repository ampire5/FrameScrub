# Slot capsule: tabs, tools and Zen timing for the slots

Date: 2026-10-28. Status: design approved in chat ("Go", 2026-10-28), not implemented. Branch: `strip-slots`
(FrameScrub; HomeScreenKit untouched). Follows the playlist strip (F1, `2026-10-27-playlist-strip-design.md`) and
the mockup «Лента во FrameScrub» (capsule with pin and chevron over the strip, 2026-10-22).

## Problem

A slot is already a Zen-style side panel (overlay / pinned / hidden, edge reveal, 150 ms hide, 200 / 100 pt overshoot),
but its top is a permanent 30 pt header band (name ▾, pin, backdrop, ✕) with the playlist's own filter row under it:
two bands of chrome above the strip, always taking room. A slot holds one view; changing it goes through the ▾ menu.
Some of the motion differs from Zen's (hide is a fade, the card sits 8 pt off the edges), and the user wants Zen's tuned
values copied rather than reinvented.

## Goals

1. **Capsule instead of header.** The slot's view gets the card's full height. A glass capsule at the card's top holds
   the tabs, the current view's tools and the slot's own buttons; in an overlay slot it shows while the pointer is over
   the card.
2. **Tabs.** A slot holds a list of views (the playlist, plugin pages); tabs in the capsule switch them with one click.
   Views once built are kept, hidden.
3. **Filter and order in the capsule.** The playlist's filter row goes; 🔍 and ⇅ sit in the capsule.
4. **Zen's show / hide.** Timings, motion and keep-open rules as in Zen's compact mode (source read at
   zen-browser/desktop `7133db8`, `src/zen/compact-mode/`).

Not in scope: the bottom timeline (F2–F4), HomeChrome tokens for the capsule (stage L3 in the kit; the capsule is built
in the app now and moves to the kit with stage 3, "slots into the kit"), Loupe.

## Behaviour

### The capsule

```
┌──────────────────────────────────┐
│ ╭──────────────────────────────╮ │  capsule: glass, 28 pt high, 6 pt from the card's edges
│ │ ▶︎ ◉ ◈ +  │ 🔍 ⇅ │ 📌 ◐ ›      │ │
│ ╰──────────────────────────────╯ │
│  view, full height of the card   │
```

- **Left: tabs.** One icon per view in the slot's order: the playlist (`play.rectangle`), each plugin page (its
  declared SF Symbol if the page gives one, else its name's first letter in a rounded square), then **+**. The tab of
  the shown view is filled (chip `rgb(255 255 255 / .2)`), others at 70 % opacity. Tooltip: the view's name.
  - Click: show that view. **+**: today's content menu (playlist, plugins, link page); the choice is added as a tab and
    shown. A view already in another slot moves here (one playlist, one page per plugin per slot as now).
  - Right click on a tab: Reload Page (pages), Move to Left / Right / Bottom Slot, Close Tab. Closing the last tab
    leaves the slot empty (today's "+" in the middle).
  - Drag of tabs to reorder: not in this stage.
- **Middle: the shown view's tools.** The playlist gives 🔍 (`magnifyingglass`) and ⇅ (`arrow.up.arrow.down`, the
  order menu, its current choice ticked; only for a folder playlist, as the popup now). A plugin page gives none.
  - 🔍 or ⌘F: a search field opens in the capsule in place of the tabs and tools (they slide out, 0.15 s), focused.
    Esc clears it, a second Esc (or Esc on an empty field) closes it; ↩ opens the first file, as now. While the filter
    holds text and the field is closed, 🔍 is drawn in the accent colour and its tooltip shows the text.
- **Right: the slot.** 📌 pin / float (`pin` / `pin.fill`), ◐ next backdrop (overlay only, as now), › hide (a chevron
  toward the slot's edge: `chevron.right` / `chevron.left` / `chevron.down`).
- Right click on the capsule's empty part: the "Hide by Itself" choices (moved out of ▾).
- **When it shows.**
  - Overlay slot: fades in (0.15 s) when the pointer enters the card, fades out 0.6 s after it left the card. It also
    shows while the slot is shown by a key with the pointer elsewhere, until the pointer comes in and leaves once.
  - Pinned slot: always shown (it is the only way to unpin by the pointer).
  - Never fades while a menu of it is open, the search field has the keyboard, or a tab is hovered.
- **Over the view, not above it.** The capsule lies over the view's top; the view is not laid out again when it shows.
  The strip already fades at its top; the table gets a top content inset of the capsule's height plus 6 pt so its first
  row can scroll clear of it. A plugin page gets the same as a CSS variable it may read (`--slot-top-inset`, set through
  the page bridge); a page that ignores it lies under the capsule's corner.
- **Look.** Glass capsule as the mockup's `.tools`: `NSVisualEffectView` `.hudWindow` + veil black .35, corner radius
  14, hairline `rgb(255 255 255 / .14)`, symbols 13 pt light text `#f2f2f7`, buttons 28×24 rounded, hover
  `rgb(255 255 255 / .1)`. On the clear backdrop the capsule keeps its own glass (it is the one place that must read on
  any picture).

### Tabs in the config

`slot-right=playlist + plugin:Stash, overlay, glass, mouse-leaves, 400, hidden, at-once` — the content field becomes a
list joined by ` + ` (space-plus-space, so a plugin name may hold `+` without spaces around it). The first entry is the
shown tab at launch; switching tabs rewrites the order so the shown tab is first. A single entry reads and writes
exactly as today (old configs and `reference.md` examples stay valid). `empty` is the empty list.

### Showing and hiding: Zen's rules

Kept (already as Zen): reveal at once with the pointer at the edge (`slot-reveal-distance`, 12 pt, a wider band than
Zen's ~5 px sliver: asked for on 2026-10-26); hide 150 ms after the pointer left (`sidebar-keep-hover.duration`); the
pointer outside the window across the slot's edge keeps it up to 200 pt (sides) / 100 pt (bottom) away, ±7 pt along;
never while typing, a menu is open, the edge is dragged, a button is held.

Changed:

| | now | Zen | new |
|---|---|---|---|
| hide motion | 0.15 s slide + fade | same 0.25 s spring translate as the show | 0.25 s spring translate back to the edge, no fade; the view is hidden at the end |
| show motion | `CASpringAnimation` stiffness 300, damping 28.4 (~0.3 s) | `linear()` spring, 0.25 s, ~1 % overshoot near 73 % | a spring settling in 0.25 s with ~1 % overshoot (stiffness and damping recomputed; the test checks `settlingDuration` and the peak) |
| card's gap to the window | 8 pt | 4 pt (half the 8 px separation) | 4 pt |
| card's shadow / outline | radius 4, offset 3, .24 / hairline .10 | `0 3px 8px` .24 / inner 1 px .15 | shadowRadius 4 (≈ CSS blur 8), offset 3, .24 / hairline .15 |
| pointer left the window not across the slot's edge | stays until it returns | hides after 1 s | hides 1 s after it left |
| the window resigns key / the app deactivates | nothing | hides | overlay slots hide (pinned stay) |
| a menu of the slot closes with the pointer outside | hides after 150 ms | waits for the pointer to come back, then the usual rules | waits (`AutoHideClock` treats it as "shown with the pointer elsewhere") |
| a leave during a window drag | not checked | re-checks the pointer before hiding | the hide re-checks `isPointer(in:)` at fire time and skips while the window is being moved |
| flash on switching the video | — | `toolbar-flash-popup`, 800 ms, off by default | `slot-flash=off` (default) / `on`: the playlist's slot shows for 0.8 s when the video changes by autoadvance or keys, unless shown already; a new switch restarts the 0.8 s |

With Reduce Motion: a 0.15 s fade both ways, as now.

## Design

- **`SlotSettings` (FrameScrubCore).** `SlotSetting.content: SlotContent` becomes `contents: [SlotContent]` (no
  `.empty` inside; empty slot = `[]`), parsed and written with ` + `. `SlotFlash` key and `Config.slotFlash`. Tests:
  round trip of one, several, empty; a plugin name with `+`; old single-content text unchanged.
- **`SlotTiming` (FrameScrubCore).** `AutoHideClock` gains `windowLeft(now:)` (pointer out of the window, not across
  the edge: hide after `outsideDelay` = 1.0), `resigned()` (hide now), `menuClosed(pointerInside:)` (as `shown`). A
  `CapsuleClock` (pure) for the capsule's fade: in on enter, out 0.6 s after leave, held while busy. `SlotMotion`:
  the spring's stiffness / damping / duration constants with the measurement of its settle and overshoot. All
  unit-tested as `AutoHideClock` is now.
- **`SlotCapsuleView` (app).** The capsule: tabs (`[SlotTab]`: id, symbol or letter, name, selected), tools (given by
  the view: `[SlotTool]`: id, symbol, tint, menu or action), slot buttons, the search field. Callbacks to `SlotView`.
  Laid out by frames, no constraints churn on tab changes; the tabs are reused buttons (a pool), not rebuilt.
- **`SlotView`.** Loses the header; holds `capsule` and a `contentHost` with one subview per tab (built once, hidden
  when not shown, `isHidden` + removed from the key view loop and VoiceOver as `CLAUDE.md` asks). Hide motion as
  above.
- **`SlotsController`.** `Slot.page` → `Slot.pages: [String: PluginPanel]` and `shown: SlotContent?`. `setContent`
  → `addTab` / `showTab` / `closeTab`; `move(_:to:)` moves one tab. The header menu splits into the tab menu and the
  capsule's menu. Window resign / app deactivate observers. Pages that are not the shown tab get `isShownInSlot =
  false` (they keep their state; their keys stop as for a hidden slot).
- **`PlaylistPanelView`.** The filter row goes; it exposes `tools` (🔍, ⇅) and `beginFilter` / `filterText` for the
  capsule's field; the table gets its top inset; the strip already fades at the top.
- **Plugin bridge.** `--slot-top-inset` posted to the page on load and when the capsule's height changes.

## Speed

Budgets of `CLAUDE.md`: switching a tab ≤ 100 ms main thread on first visit of a built view and ≤ 16 ms on return
(nothing rebuilt); showing the capsule ≤ 2 ms (opacity only). The bench (`FrameScrubBench slots`, new) drives a real
window with a slot of three tabs (playlist strip, two blank pages), CPU time per action (`CLOCK_THREAD_CPUTIME_ID`),
first visit and return, five rounds; the results go to `docs/bench/2026-10-28-slot-capsule.md`. No timers at rest: the
capsule's fade-out is one scheduled block, cancelled on re-enter; the auto-hide poll stays as it is (only while an
overlay slot is shown).

## Testing

- Core unit tests: settings (tabs), clocks (window left, resign, menu closed, capsule), motion constants.
- App: build, full suite; a dev-build check with `CFFIXED_USER_HOME` and window screenshots: the capsule in overlay and
  pinned, three tabs, the search field open, each backdrop. Pointer behaviour (enter / leave timings, overshoot, the
  flash) is checked by hand by the user; it cannot be synthesized without moving their pointer.

## Also on this branch before the merge

Not part of the capsule, done in the same pass so `strip-slots` can go into `polish-2`:

1. Deferred minor 17: `FileFactsStore.set` on main may wait on the lock held by a background `all()` — move the write
   off the lock's critical read path (copy-on-write snapshot) and measure.
2. Deferred minor 18: the strip bench drives the kit view, not `PlaylistStripView` — move the glue the bench needs into
   a testable type or note why not (decided when the capsule bench is written; both benches share the window setup).
3. The window no longer reshaped by crop detection (7b3f158): checked by hand by the user in the dev build.
4. A dev build launched next to the installed app once showed a file it was not given (2026-10-27, not reproduced
   since): find how files pass between running FrameScrubs and make a build take only what is addressed to its own
   bundle.

Then: `polish-2` merged in again, suites green, `strip-slots` merged into `polish-2` in FrameScrub, HomeScreenKit
(kit tagged so FrameScrub's pin resolves) and Loupe, and the apps built (installed only on the user's word).
