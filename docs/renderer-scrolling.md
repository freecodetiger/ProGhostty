# Renderer Scrolling

ProGhostty's **primary** interactive terminal scroll path is Pattern-2 (default
`smoothPixelScrollingEnabled = true`, primary screen, browse handlers wired):

```text
trackpad / wheel event
    -> PTYGridView.scrollWheel / feedSmoothScroll
    -> SmoothScrollEngine (display-link)
    -> SmoothScrollBrowseResolver
    -> browseTopRow + viewport.visualOffsetY
    -> PTYTerminalSurfaceRegistry.presentBrowseWindow
    -> GhosttyVTBridge.rows(at:)     # VT viewport stays at live bottom
    -> GhosttyTerminalScrollFrame (1 + viewport + 1 overscan)
    -> Metal / cell-grid draw with sub-row translation
```

**Fallback** when smooth is off, alternate screen is active, or browse plumbing
is missing:

```text
trackpad / wheel event
    -> PTYGridView.processScroll
    -> PaneScrollController
         (PaneScrollCoordinator + ScrollCommitCoordinator ~120 Hz)
    -> GhosttyVTBridge.scrollViewport
    -> GhosttyTerminalScrollFrame
    -> render + resetViewportStartRowKeepingVisualOffset
```

The core rule remains unchanged: `libghostty-vt` owns terminal state. Pattern-2
is a **read window** over scrollback (`rows(at:)`), not a second authoritative
viewport. The UI may keep a sub-row pixel remainder for presentation, but it
must not maintain an independent scrollback mirror.

## Goals

- Preserve TUI correctness for Codex, Claude Code, vim, tmux, fzf, htop, and other live terminal programs.
- Keep PTY, libghostty viewport, cursor state, selection mapping, and renderer state aligned.
- Prefer Pattern-2 browse (no VT move while scrolling history) on the default path.
- Avoid synchronous `scrollViewport -> render -> flush` on every high-frequency trackpad event (fallback path still coalesces).
- Keep resize-sensitive screens from reflowing while the user drags the window.

## Pattern-2 browse

While browsing:

- Continuous position lives in `SmoothScrollEngine` (distance-from-bottom model).
- Tick resolves `(topAbsoluteRow, pixelOffset)` and is the **sole writer** of
  `viewport.visualOffsetY`.
- `browseTopRow` parks history after the gesture settles; new output re-presents
  the same absolute window (no history freeze).
- Returning to the live tail clears `browseTopRow` and resumes the live frame.

Selection edge auto-scroll (drag past top/bottom inset) must use the same browse
present path when Pattern-2 is available — discrete whole-row steps on
`browseTopRow` via `browsePresentHandler` / `browseFollowResumeHandler`, **not**
`scrollViewport`. Can-scroll for that path is derived from browse metrics, not
the VT scrollbar (VT stays pinned at bottom during Pattern-2).

`resetViewportStartRowKeepingVisualOffset` is a no-op for visual offset while
`browseTopRow != nil` or smooth browsing is active, so fallback VT commits
cannot wipe Pattern-2 sub-row offset.

## Fallback overscan row commits

On the fallback path, pixel-level scroll is only enabled when `libghostty-vt`
can provide a `GhosttyTerminalScrollFrame` with real overscan rows.
`PaneScrollCoordinator` keeps `pixelRemainderY` within one cell height; when a
full row accumulates, `ScrollCommitCoordinator` coalesces commits (~120 Hz) into
`scrollViewport`.

Slow trackpad single-row wrap still commits immediately when there is no pending
batch, so remainder wrap does not twitch ahead of the VT row.

## Dirty Drawing

Overscan rows by themselves do not require a full redraw. The cell-grid
renderer can still use dirty-row invalidation when there is no active sub-row
visual transform. A full redraw is used when `visualOffsetY` is non-zero
because the whole extended grid is translated.

## Diagnostics

Renderer diagnostics expose scroll behavior (`scrollMode`, `pixelSmoothScroll`,
`pixelRemainderY`, commit/pending counters, etc.). Treat coordinator fields as
meaningful on the **fallback** path; Pattern-2 browse position is
`browseTopRow` + engine/`visualOffsetY`.

## Tests

Regression coverage includes:

- Pattern-2: display-link tick drives present without VT move; park/clear
  `browseTopRow`; geometry red line; remainder reset does not wipe P while
  browsing.
- Selection auto-scroll: without browse handlers, still uses VT scroll handler;
  with Pattern-2 plumbing, uses browse present only.
- Fallback: high-frequency wheel coalescing, slow single-row immediate commit,
  alternate-screen forward to program, pin/input reset to live bottom.

## Non-Goals

The primary terminal renderer must not:

- use HTML/WKWebView for interactive terminal rendering
- use TextKit as the main terminal scrollback model
- keep a UI-side scrollback mirror as a second authority
- move VT viewport during Pattern-2 history browse
- prioritize scroll animation over PTY/libghostty correctness
