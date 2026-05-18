# Renderer Scrolling

ProGhostty's primary interactive terminal scroll path is:

```text
trackpad / wheel event
    -> PTYGridView
    -> PaneScrollCoordinator
    -> ScrollCommitCoordinator
    -> libghostty-vt viewport
    -> GhosttyTerminalScrollFrame
    -> AppKit cell-grid draw
```

The core rule remains unchanged: `libghostty-vt` owns terminal state. The UI may keep a sub-row pixel remainder for presentation, but it must not maintain an independent scrollback mirror or fake the authoritative viewport.

## Goals

- Preserve TUI correctness for Codex, Claude Code, vim, tmux, fzf, htop, and other live terminal programs.
- Keep PTY, libghostty viewport, cursor state, selection mapping, and renderer state aligned.
- Avoid synchronous `scrollViewport -> render -> flush` on every high-frequency trackpad event.
- Use pixel movement only when the snapshot contains real overscan rows.
- Keep resize-sensitive screens from reflowing while the user drags the window.

## Overscan Pixel Scrolling

Pixel-level scroll is only enabled when `libghostty-vt` can provide a `GhosttyTerminalScrollFrame` containing:

- the visible viewport
- overscan rows above the viewport
- overscan rows below the viewport
- the libghostty viewport start row

`PTYGridView` draws the extended frame and applies `visualOffsetY` only within one cell height. Once accumulated trackpad delta crosses a full row, ProGhostty commits a row delta to the libghostty viewport.

The important invariants are:

- `pixelRemainderY` is always smaller than one row height.
- `visualOffsetY` only shifts real overscan content.
- row movement is committed back to libghostty.
- alternate-screen/TUI wheel input is forwarded to the program instead of using ProGhostty scrollback.
- HTML/TextKit are not used as the primary interactive terminal renderer.

## Scroll Commit Coalescing

Trackpads can emit many small wheel events in a short time. Committing each event synchronously caused the main event path to do too much work:

```text
wheel event
    -> libghostty scrollViewport
    -> scroll snapshot
    -> renderer update
    -> AppKit flush
```

`ScrollCommitCoordinator` reduces this pressure by collecting row deltas and committing them once per short display-oriented interval. This keeps fast scroll gestures from forcing one libghostty snapshot and one renderer flush per wheel event.

The default commit interval is currently about 120 Hz. This is intentionally short: it coalesces bursts without letting the visible scroll position lag far behind the authoritative libghostty viewport.

## Slow Trackpad Edge Case

Slow trackpad scrolling exposed a subtle instability. When several small deltas accumulated to one row, `pixelRemainderY` wrapped from nearly one cell height back to a small remainder. If the row delta was delayed until the next coalesced commit, the visible sub-row offset moved before libghostty's viewport moved. Users experienced this as a small twitch or unstable slow scroll.

The fix is narrowly scoped:

- If a single-row movement is produced by accumulated small deltas and there is no pending commit, ProGhostty commits that row immediately.
- If a fast gesture already has a pending commit, new row deltas continue to be coalesced.

This keeps slow trackpad crossing stable without returning to synchronous commits for fast scroll bursts.

## Dirty Drawing

Overscan rows by themselves do not require a full redraw. The cell-grid renderer can still use dirty-row invalidation when there is no active sub-row visual transform.

A full redraw is used when `visualOffsetY` is non-zero because the whole extended grid is translated. Once the row commit lands and the remainder is stable, normal dirty-row behavior resumes.

This keeps Codex-style long histories cheaper to scroll while preserving correctness for cells entering and leaving the viewport.

## Diagnostics

Renderer diagnostics expose the current scroll behavior:

- `scrollMode`
- `pixelSmoothScroll`
- `pixelSmoothScrollReason`
- `pixelRemainderY`
- `committedRowDelta`
- `coalescedWheelEvents`
- `scrollCommitMode`
- `pendingScrollRowDelta`
- `pendingScrollWheelEvents`
- `scrollCommitMs`
- `scrollRenderMs`

These fields distinguish between three common bottlenecks:

- event pressure: many wheel events before a commit
- bridge pressure: expensive `libghostty-vt` viewport commits or snapshots
- draw pressure: expensive AppKit cell-grid rendering

## Tests

The current regression coverage includes:

- high-frequency wheel events do not synchronously call the viewport scroll handler
- many wheel events are committed as one coalesced row delta
- slow trackpad accumulated single-row movement commits before the visual remainder wraps
- row commits still reach libghostty and update rendered scrollback
- pixel remainder stays within one row height
- alternate-screen wheel input is forwarded to the TUI program
- pinned output and user input reset pixel scroll state and return to the live bottom

## Non-Goals

The primary terminal renderer must not:

- use HTML/WKWebView for interactive terminal rendering
- use TextKit as the main terminal scrollback model
- keep a UI-side scrollback mirror
- fake libghostty viewport state with a local transform when overscan rows are unavailable
- prioritize scroll animation over PTY/libghostty correctness

Future work should continue to improve the bridge and renderer diagnostics rather than adding a second authoritative scroll model.
