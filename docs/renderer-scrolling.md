# Renderer Scrolling

ProGhostty currently uses row-based scrolling for the primary interactive terminal.

The active terminal renderer is a cell-grid view backed by `libghostty-vt`. PTY bytes are written into libghostty, libghostty owns the terminal viewport, and ProGhostty renders the current libghostty snapshot. This keeps the PTY, terminal parser, TUI state, cursor state, and renderer state aligned.

## Current Policy

- Scrollback movement is owned by `libghostty-vt`.
- The UI sends row deltas to libghostty's viewport API.
- The cell-grid renderer redraws the resulting libghostty snapshot.
- Dirty-row rendering remains enabled for normal terminal updates.
- Local `visualOffsetY` is not used to move terminal content in the default renderer path.

Renderer diagnostics should report:

- `scrollMode=row-based`
- `pixelSmoothScroll=unavailable`
- `pixelSmoothScrollReason="missing overscan rows from libghostty-vt snapshot"`

## Why Not UI Transform Scrolling

A UI transform can make scrolling appear smoother by temporarily shifting the rendered grid by a few pixels. That is not a correct terminal state unless the renderer also has real rows above and below the visible viewport.

The current cell-grid snapshot only contains the current libghostty viewport. If AppKit shifts that snapshot locally, the UI can briefly show a state that libghostty does not own. When libghostty then produces the real scrolled viewport, the view snaps back to the authoritative state. This caused one-frame flicker, apparent offset, and occasional scroll jitter.

For the primary terminal, ProGhostty must not fake viewport state in the UI layer.

## Why Smooth Pixel Scrolling Needs Overscan Rows

Correct pixel scrolling requires drawing content outside the visible area:

- rows above the viewport when scrolling up into history
- rows below the viewport when scrolling down toward the active screen
- stable cursor and selection mapping across the overscan region
- dirty tracking that accounts for rows entering and leaving the visible area

Without those overscan rows, sub-row movement exposes background or stale cells at the viewport edges. Any local transform is only moving a partial snapshot, not a complete terminal document.

## Future Direction

Smooth scrolling can be revisited as a renderer capability, not a UI trick.

The preferred research path is extending the libghostty bridge so a cell-grid snapshot can include overscan rows around the current viewport. A future implementation should:

1. Request the current viewport plus configurable overscan rows from libghostty.
2. Keep libghostty as the only owner of viewport position.
3. Render overscan rows in the cell-grid backend.
4. Apply pixel interpolation only across real snapshot rows.
5. Preserve dirty-row rendering by mapping dirty rows through the overscan window.
6. Keep TUI alternate-screen rendering stable and avoid switching primary renderer paths.

TextKit or HTML renderers may still be useful for read-only transcript or history surfaces, but they should not replace the primary interactive terminal renderer.
