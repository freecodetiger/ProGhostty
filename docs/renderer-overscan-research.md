# Renderer Overscan Research

## Decision

Status: `available`

The current vendored Ghostty C API does not expose a render-state row iterator for rows outside the current viewport. The render state remains viewport-only.

There is, however, a non-mutating terminal grid reference path:

```text
ghostty_terminal_grid_ref(terminal, GhosttyPoint{ .tag = SCREEN, ... })
  -> ghostty_grid_ref_cell
  -> ghostty_grid_ref_graphemes
  -> ghostty_grid_ref_style
```

This can read specific rows above or below the current viewport by using `GHOSTTY_POINT_TAG_SCREEN` coordinates. The screen row for the top of the current viewport can be derived from `GHOSTTY_TERMINAL_DATA_SCROLLBAR.offset`.

This is acceptable only for a small overscan window, such as one or two rows above and below the visible viewport. It must not be used to replace the normal render-state row iterator for full-screen rendering.

## Required Invariant

The UI must not invent scrollback rows. Pixel scrolling may only use rows returned by libghostty-vt.

## API Findings

- Render state row iterator:
  - `GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR` only iterates the render state's visible viewport.
  - It is still the correct API for the main cell-grid viewport.
- Terminal viewport APIs:
  - `ghostty_terminal_scroll_viewport` mutates the real viewport.
  - This remains the only way to commit whole-row scroll movement.
- Scrollbar APIs:
  - `GHOSTTY_TERMINAL_DATA_SCROLLBAR` returns `total`, `offset`, and `len`.
  - `offset` is the current viewport's row offset from the top of the full screen.
  - `len` is the visible viewport height in rows.
- Non-mutating overscan row access:
  - `ghostty_terminal_grid_ref` accepts `GHOSTTY_POINT_TAG_SCREEN`.
  - `ghostty_grid_ref_cell`, `ghostty_grid_ref_graphemes`, and `ghostty_grid_ref_style` can extract cell content and style for a resolved grid ref.
  - Ghostty documents this path as not suitable for a full render loop because `screen` and `history` lookups may traverse scrollback.
  - ProGhostty may use it only for bounded overscan rows, not for normal viewport rows.

## Implementation Consequence

Implement `GhosttyVTBridge.scrollFrame(overscanTop:overscanBottom:)`.

The implementation must:

- Use the existing `GhosttyVTBridge.frame()` / render-state path for the visible viewport.
- Use `ghostty_terminal_grid_ref` only for overscan rows outside the viewport.
- Clamp `overscanTop` and `overscanBottom` to available screen rows.
- Return empty overscan arrays when the terminal is on the alternate screen or when no scrollback context exists.
- Keep diagnostics at unavailable unless at least one real overscan row is returned.
- Keep the default renderer row-based until the experimental pixel-scroll flag is set.

If this path is too slow in runtime testing, fall back to:

```text
pixel smooth scroll: unavailable
reason: missing overscan rows from libghostty-vt snapshot
```
